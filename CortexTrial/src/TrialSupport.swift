// Cortex integration glue for the AGPL-3.0 Sentient trial. No telemetry or permission overrides.
import Foundation
import AppKit

nonisolated enum DirectMCPRuntime {
    static func quoted(_ text: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!
    }
}
nonisolated enum OpenAIComputerUse {
    struct Configuration: Sendable {
        let cliURL: URL
        let clientEnvironment: [String: String]
        let codexOverrides: [String]
        init() throws {
            let env = ProcessInfo.processInfo.environment
            let home = env["CORTEX_TRIAL_CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
            let bundled = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
            let cli = env["CORTEX_TRIAL_CODEX"] ?? (FileManager.default.isExecutableFile(atPath: bundled) ? bundled : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path)
            cliURL = URL(fileURLWithPath: cli).resolvingSymlinksInPath()
            let helper = URL(fileURLWithPath: home).appendingPathComponent("computer-use/Codex Computer Use.app")
            let client = helper.appendingPathComponent("Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient")
            guard FileManager.default.isExecutableFile(atPath: cliURL.path), FileManager.default.isExecutableFile(atPath: client.path) else {
                throw NSError(domain: "CortexTrial", code: 1, userInfo: [NSLocalizedDescriptionKey: "Install Codex CLI and its native computer-use helper before this trial."])
            }
            // Check the installed dependency; do not copy, replace or terminate the shared helper.
            for bundle in [helper, helper.appendingPathComponent("Contents/SharedSupport/SkyComputerUseClient.app")] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                process.arguments = ["--verify", "--deep", "--strict", "--test-requirement==anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\"", bundle.path]
                process.standardOutput = FileHandle.standardError
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw NSError(domain: "CortexTrial", code: 2, userInfo: [NSLocalizedDescriptionKey: "Native helper signature verification failed."]) }
            }
            var selected = env.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH"].contains($0.key) }
            selected["CODEX_CLI_PATH"] = cliURL.path
            selected["CODEX_HOME"] = home
            clientEnvironment = selected
            codexOverrides = ["mcp_servers.sentient_native.command=\(DirectMCPRuntime.quoted(client.path))",
                "mcp_servers.sentient_native.args=[\"mcp\"]", "mcp_servers.sentient_native.required=true",
                "mcp_servers.sentient_native.default_tools_approval_mode=\"approve\"",
                "mcp_servers.sentient_native.tool_timeout_sec=120"] + selected.sorted { $0.key < $1.key }.map {
                    "mcp_servers.sentient_native.env.\($0.key)=\(DirectMCPRuntime.quoted($0.value))"
                }
        }
    }
}
// Sentient's diagnostics hooks are intentionally inert in the isolated trial.
nonisolated struct CaptureDiagnostics: Sendable {
    enum Source { case native, healthProbe }
    enum Outcome { case started, passed, failed, recovered, cancelled, skipped }
    init(source: Source, context: CaptureDiagnostics? = nil) {}
    @MainActor static func environment(target: NSRunningApplication? = nil) -> [String: String] { [:] }
    func record(_ outcome: Outcome, attempt: Int = 1, failure: NativeComputerUseFailure? = nil, fields: [String: String] = [:]) {}
}
@MainActor final class NativePermissionCheck {
    static let shared = NativePermissionCheck()
    // No local grant cache: actual native errors are returned to the caller unchanged.
    func invalidate(failure: NativeComputerUseFailure? = nil) {}
}
