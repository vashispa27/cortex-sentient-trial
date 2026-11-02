// Cortex trial adaptation: removes Sentient-specific diagnostic UI/consent; core transport,
// freshness checks, idempotency and retry logic remain upstream. AGPL-3.0.
// Per-task native MCP boundary: authenticates through Codex, preserves native state/action IDs,
// and retries transient app-state reads before they reach the model. Never retries actions.
// Doc: Documentation - Native Computer Use.md

import Foundation
import AppKit
import CryptoKit

actor NativeComputerUseServer {
    private let diagnosticContext = CaptureDiagnostics(source: .native)
    private let origin: OriginTarget?
    private let configuration: OpenAIComputerUse.Configuration
    private let resolveTarget: @MainActor @Sendable (String) -> String?
    private var session: OpenAIComputerUseSession?
    private var openingSession: Task<OpenAIComputerUseSession, Error>?
    private var transport: LocalMCPServer?
    private var tools: [[String: Any]] = []
    private var closed = false
    private var busy = false
    private var verified: Set<String> = []
    private var fingerprints: [Data: Data] = [:]
    private var replies: [Data: Data] = [:]
    private var replyOrder: [Data] = []
    private var replyBytes = 0
    private var duplicatedURLs: Set<String> = []
    private static let nativeNames: Set<String> = ["list_apps", "get_app_state", "click", "perform_secondary_action",
        "set_value", "select_text", "scroll", "drag", "press_key", "type_text"]
    private static let names = nativeNames.union(["duplicate_tab_in_background"])

    init(configuration: OpenAIComputerUse.Configuration, origin: OriginTarget? = nil,
         resolveTarget: @escaping @MainActor @Sendable (String) -> String? = { NativeComputerUseServer.target($0) }) {
        self.origin = origin
        self.configuration = configuration
        self.resolveTarget = resolveTarget
    }

    func start() async throws -> LocalMCPServer.Connection {
        do {
            let session = try await openSession()
            self.session = session
            let data = try await session.catalog()
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = object["data"] as? [[String: Any]],
                  let server = servers.first(where: { $0["name"] as? String == "sentient_native" }),
                  let catalog = server["tools"] as? [String: [String: Any]] else {
                throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: .catalog)
            }
            tools = catalog.values.filter { Self.nativeNames.contains($0["name"] as? String ?? "") }
                .sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
            guard Set(tools.compactMap { $0["name"] as? String }) == Self.nativeNames else {
                throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: .catalog)
            }
            tools.append(["name":"duplicate_tab_in_background",
                "description":"Duplicate the currently displayed Chromium page into one new background tab in the originating window, restoring the original selected tab. Use after opening each requested email normally in the original tab; then go back to the search results. Does not depend on links supporting middle-click. Verifies exactly one new tab, never selects an existing different tab, and deduplicates the current URL. Only use when the user requested new tabs. Call alone.",
                "inputSchema":["type":"object","properties":[:],"additionalProperties":false]])
            try Task.checkCancellation()
            let transport = LocalMCPServer(name: "sentient_native", tools: Self.names.sorted(), timeout: 130,
                maximumBody: 1_048_576) { [weak self] request in
                guard let self else { throw CancellationError() }
                return try await self.respond(request)
            }
            self.transport = transport
            return try await transport.start()
        } catch {
            CaptureDiagnostics(source: .native, context: diagnosticContext).record(.failed, failure: error as? NativeComputerUseFailure)
            await stop(); throw error
        }
    }
    func stop() async {
        closed = true
        let opening = openingSession
        opening?.cancel()
        await transport?.stop(); transport = nil
        await session?.close(); session = nil
        if let opened = try? await opening?.value { await opened.close() }
        replies.removeAll(); fingerprints.removeAll(); tools.removeAll()
        verified.removeAll()
    }
    func respond(_ data: Data) async throws -> Data {
        guard !closed, let rpc = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = rpc["id"] else { throw CancellationError() }
        func reply(_ result: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result]) }
        switch rpc["method"] as? String {
        case "initialize":
            let params = rpc["params"] as? [String: Any]
            return try reply(["protocolVersion": params?["protocolVersion"] as? String ?? "2024-11-05",
                "capabilities": ["tools": [:]], "serverInfo": ["name": "Sentient native computer use", "version": "1"]])
        case "ping": return try reply([:])
        case "tools/list": return try reply(["tools": tools])
        case "tools/call":
            guard let params = rpc["params"] as? [String: Any], let tool = params["name"] as? String,
                  Self.names.contains(tool), let arguments = params["arguments"] as? [String: Any] else {
                verified.removeAll()
                return try reply(Self.errorResult(.init(kind: .unknown, code: -32602, detail: .malformedResponse, stage: .transport)))
            }
            // AXPress can ignore non-left mouse semantics. Require the native pixel-input path
            // instead of letting an intended background-tab action become ordinary navigation.
            if tool == "click", let button = arguments["mouse_button"] as? String, button != "left",
               arguments["element_index"] != nil || arguments["x"] == nil || arguments["y"] == nil {
                return try reply(["isError": true, "content": [["type": "text", "text": "Non-left clicks require fresh screenshot x/y coordinates and no element_index. Accessibility element clicks may act as ordinary left clicks. Re-read state and use the pixel-input path; no click was dispatched."]]])
            }
            // Keep compact consumed-ID hashes for this task. A fixed count ceiling made
            // every later request fail permanently, including attempts to recover.
            let key = Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: id, options: [.fragmentsAllowed, .sortedKeys])))
            let fingerprint = Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: params, options: .sortedKeys)))
            if let old = fingerprints[key] {
                guard old == fingerprint, let response = replies[key] else {
                    verified.removeAll()
                    return try reply(Self.errorResult(.init(kind: .unknown, code: nil, detail: .staleState, stage: .action)))
                }
                return response
            }
            guard !busy else {
                verified.removeAll()
                return try reply(Self.errorResult(.init(kind: .connection, code: nil, detail: .concurrentCall, stage: .transport)))
            }
            fingerprints[key] = fingerprint
            busy = true
            defer { busy = false }
            let payload: [String: Any]
            do {
                if let origin {
                    guard tool != "list_apps" else { throw OriginTargetError.unavailable("App discovery is outside this window-bound task") }
                    try await origin.check(app: arguments["app"] as? String, key: arguments["key"] as? String)
                }
                let result = tool == "duplicate_tab_in_background" ? try await duplicateTab() : try await call(tool, arguments: arguments)
                if let origin {
                    if tool == "get_app_state" { try await origin.verifyState(result) }
                    try await origin.check()
                }
                payload = result
            }
            catch is CancellationError { throw CancellationError() }
            catch {
                verified.removeAll()
                if let originError = error as? OriginTargetError {
                    return try reply(["isError": true, "content": [["type": "text", "text": originError.description]]])
                }
                let failure = (error as? NativeComputerUseFailure) ?? .init(kind: .connection, code: nil, detail: .malformedResponse, stage: .transport)
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                payload = Self.errorResult(failure)
            }
            let response = try reply(payload)
            replies[key] = response; replyOrder.append(key); replyBytes += response.count
            // Never replay an evicted action. Its fingerprint remains as a consumed request ID.
            while replyOrder.count > 8 || replyBytes > 32 * 1_048_576 {
                let oldest = replyOrder.removeFirst()
                replyBytes -= replies.removeValue(forKey: oldest)?.count ?? 0
            }
            return response
        default:
            return try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id,
                "error": ["code": -32601, "message": "Method unavailable"]])
        }
    }

    private func duplicateTab() async throws -> [String:Any] {
        guard let origin else { throw OriginTargetError.unavailable("No originating window is bound") }
        let path=origin.descriptor.app_path
        let state=try await call("get_app_state",arguments:["app":path])
        try await origin.verifyState(state)
        let text=(state["content"] as? [[String:Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator:"\n")
        let root=text.components(separatedBy:"\n").first { $0.hasPrefix("0 ") } ?? ""
        guard let range=root.range(of:"URL: ") else { throw OriginTargetError.unavailable("Current page URL is not visible") }
        let url=String(root[range.upperBound...]).components(separatedBy:", Secondary Actions:")[0].trimmingCharacters(in:.whitespaces)
        guard !url.isEmpty else { throw OriginTargetError.unavailable("Current page URL is empty") }
        if duplicatedURLs.contains(url) {
            return ["content":[["type":"text","text":"This URL was already duplicated or attempted in this task. Inspect the tab strip before proceeding; no second tab was created."]]]
        }
        let previous=try await origin.beginDuplication()
        // Consume before dispatch. An uncertain tab creation must not be automatically repeated.
        duplicatedURLs.insert(url)
        _ = try await call("press_key",arguments:["app":path,"key":"super+l"])
        try await origin.check()
        _ = try await call("press_key",arguments:["app":path,"key":"alt+Return"])
        try await origin.checkWindowOnly()
        _ = try await call("get_app_state",arguments:["app":path])
        let count=try await origin.restoreAfterDuplication(previous)
        let restored=try await call("get_app_state",arguments:["app":path])
        try await origin.verifyState(restored)
        return ["content":[["type":"text","text":"Created exactly one background copy of the current page; restored the original selected tab. Window now has \(count) tabs. Continue in the original tab; use Back to return to results before the next email."]] + (restored["content"] as? [[String:Any]] ?? [])]
    }

    private func openSession() async throws -> OpenAIComputerUseSession {
        let configuration = configuration
        let opening = Task { try await OpenAIComputerUseSession.open(configuration) }
        openingSession = opening
        defer { openingSession = nil }
        let opened = try await withTaskCancellationHandler {
            try await opening.value
        } onCancel: { opening.cancel() }
        guard !closed, !Task.isCancelled else { await opened.close(); throw CancellationError() }
        return opened
    }

    /// Recovery follows a new model-requested read. Never replay an action or
    /// restart a healthy session merely because a native tool returned an error.
    private func currentSession(for tool: String) async throws -> OpenAIComputerUseSession {
        guard !closed else { throw CancellationError() }
        if let session, await session.isUsable() { return session }
        verified.removeAll()
        guard tool == "get_app_state" || tool == "list_apps" else {
            throw NativeComputerUseFailure(kind: .unknown, code: nil, detail: .staleState, stage: .action)
        }
        await session?.close(); session = nil
        let diagnostics = CaptureDiagnostics(source: .native, context: diagnosticContext)
        diagnostics.record(.started, fields: ["recovery_decision": "reopen_on_read", "tool": tool])
        let opened = try await openSession()
        session = opened
        diagnostics.record(.recovered, fields: ["recovery_decision": "reopen_on_read", "tool": tool])
        return opened
    }

    private func call(_ tool: String, arguments: [String: Any]) async throws -> [String: Any] {
        guard !closed else { throw CancellationError() }
        let diagnostics = CaptureDiagnostics(source: .native, context: diagnosticContext)
        let isState = tool == "get_app_state"
        let selector = arguments["app"] as? String
        let target = await MainActor.run { selector.flatMap { Self.resolve($0) } }
        let identity = await targetIdentity(selector)
        if tool != "list_apps", !isState, identity.map({ verified.contains($0) }) != true {
            verified.removeAll()
            throw NativeComputerUseFailure(kind: .unknown, code: nil, detail: .staleState, stage: .action)
        }
        let encoded = try JSONSerialization.data(withJSONObject: arguments)
        let evidence = await CaptureDiagnostics.environment(target: target)
        let began = ProcessInfo.processInfo.systemUptime
        var attempt = 1
        do {
            let session = try await currentSession(for: tool)
            while true {
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                let elapsed = max(0, ProcessInfo.processInfo.systemUptime - began)
                let remaining = NativeAppStateRetry.timeout - elapsed
                if isState && remaining <= 0 {
                    throw NativeComputerUseFailure(kind: .timeout, code: nil, detail: .requestTimedOut, stage: .appState)
                }
                do {
                    // All retries share one deadline inside the outer 130s MCP timeout.
                    // A timed-out client request closes its transport and is not retryable.
                    let data = try await session.call(tool, arguments: encoded, timeout: isState ? remaining : 125)
                    try Task.checkCancellation()
                    guard !closed else { throw CancellationError() }
                    guard var result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: .transport)
                    }
                    if NativeComputerUseFailure.isError(result) {
                        throw NativeComputerUseFailure.classify(result, stage: isState ? .appState : .action)
                    }
                    if isState {
                        result = try OpenAIComputerUseProbe.appStateResult(result)
                        let current = await targetIdentity(selector)
                        try Task.checkCancellation()
                        guard !closed else { throw CancellationError() }
                        if let current { verified.insert(current) }
                        diagnostics.record(attempt == 1 ? .passed : .recovered, attempt: attempt,
                            fields: evidence.merging([
                                "duration_ms": String(Int((ProcessInfo.processInfo.systemUptime - began) * 1000)),
                                "image_valid": String((result["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "image" } == true)
                            ]) { _, new in new })
                    }
                    return result
                } catch {
                    guard !Task.isCancelled, !closed else { throw CancellationError() }
                    guard isState, let failure = error as? NativeComputerUseFailure,
                          let delay = NativeAppStateRetry.delay(afterAttempt: attempt, failure: failure,
                              elapsed: ProcessInfo.processInfo.systemUptime - began) else { throw error }
                    if let identity { verified.remove(identity) }
                    // Transient attempts stay internal: one model tool call remains pending.
                    // The final failed read reaches the model, which decides the next step.
                    diagnostics.record(.skipped, attempt: attempt, failure: failure,
                        fields: evidence.merging(["tool": tool, "recovery_decision": "wait_and_reread",
                            "duration_ms": String(Int((ProcessInfo.processInfo.systemUptime - began) * 1000))]) { _, new in new })
                    try await Task.sleep(for: .seconds(delay))
                    attempt += 1
                }
            }
        } catch {
            verified.removeAll()
            let fields = evidence.merging(["tool": tool,
                "duration_ms": String(Int((ProcessInfo.processInfo.systemUptime - began) * 1000))]) { _, new in new }
            if error is CancellationError || Task.isCancelled || closed {
                diagnostics.record(.cancelled, attempt: attempt, fields: fields)
                throw CancellationError()
            }
            var failure = (error as? NativeComputerUseFailure)
                ?? .init(kind: .connection, code: nil, detail: .malformedResponse, stage: .transport)
            failure.actionEffectsUnconfirmed = tool != "list_apps" && !isState
            if failure.kind == .permission {
                let permissionFailure = failure
                await MainActor.run { NativePermissionCheck.shared.invalidate(failure: permissionFailure) }
            }
            diagnostics.record(.failed, attempt: attempt, failure: failure, fields: fields)
            throw failure
        }
    }

    @MainActor private static func resolve(_ selector: String) -> NSRunningApplication? {
        let matches = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && ($0.bundleIdentifier == selector || $0.bundleURL?.path == selector
                || $0.localizedName?.caseInsensitiveCompare(selector) == .orderedSame)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    @MainActor private static func target(_ selector: String) -> String? {
        resolve(selector)?.bundleURL?.standardizedFileURL.path
    }

    private func targetIdentity(_ selector: String?) async -> String? {
        guard let selector else { return nil }
        return await resolveTarget(selector)
    }

    private static func errorResult(_ failure: NativeComputerUseFailure) -> [String: Any] {
        var evidence: [String: Any] = ["version": 1, "kind": failure.kind.rawValue, "detail": failure.detail.rawValue,
            "stage": failure.stage.rawValue,
            "effects_may_be_unknown": failure.effectsMayBeUnknown]
        if let code = failure.code { evidence["native_code"] = code }
        var lines = ["\(failure.code.map { "Computer Use server error \($0): " } ?? "Native computer use failed: ")\(failure.detail.rawValue)"]
        if let detail = failure.modelError { lines.append("Native error detail: " + detail) }
        lines.append(failure.modelGuidance)
        // Codex's model-facing failed-tool formatter retains only the first text block.
        // Preserve the actual native error and recovery guidance together in that block.
        return ["isError": true, "content": [["type": "text", "text": lines.joined(separator: "\n")]],
            "structuredContent": ["sentient_native_failure": evidence]]
    }
}
