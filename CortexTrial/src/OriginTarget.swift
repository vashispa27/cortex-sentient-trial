// Cortex trial target binding. AGPL-3.0 as part of the Sentient fork.
import AppKit
import ApplicationServices
import Foundation

@_silgen_name("_AXUIElementGetWindow") private func axWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

struct OriginDescriptor: Codable, Sendable {
    let app_path: String
    let pid: Int32
    let launch_timestamp: Double
    let window_id: UInt32
    let window_title: String
    let tab_hash: UInt?
    let captured_at: Double
}

enum OriginTargetError: Error, CustomStringConvertible {
    case unavailable(String)
    var description: String { switch self { case .unavailable(let reason): "ORIGIN_TARGET_BLOCKED: \(reason). Stop; do not select another window or tab." } }
}

@MainActor final class OriginTarget {
    let descriptor: OriginDescriptor
    private let window: AXUIElement
    private let tab: AXUIElement?
    private var blocked: String?

    private static func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.08)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attr(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func number(_ window: AXUIElement) throws -> UInt32 {
        var id: CGWindowID = 0
        guard axWindowID(window, &id) == .success, id > 0 else { throw OriginTargetError.unavailable("The originating window has no stable ID") }
        return id
    }
    private static func tabElements(_ window: AXUIElement) throws -> [AXUIElement] {
        var pending: [(AXUIElement, Int)] = [(window,0)]
        var selected: [AXUIElement] = []
        var visited = Set<UInt>()
        let deadline = Date().addingTimeInterval(0.5)
        while let (node,depth) = pending.popLast() {
            guard Date() < deadline, visited.count < 1500 else { throw OriginTargetError.unavailable("The originating tab could not be identified within the read budget") }
            guard visited.insert(CFHash(node)).inserted else { continue }
            let role = attr(node,"AXRole") as? String ?? ""
            if role == "AXWebArea" { continue } // Page/form contents are not target identity.
            if attr(node,"AXSubrole") as? String == "AXTabButton" { selected.append(node) }
            if depth < 10 {
                for child in attr(node,"AXChildren") as? [AXUIElement] ?? [] { pending.append((child,depth+1)) }
            }
        }
        return selected
    }
    private static func selectedTab(_ window: AXUIElement) throws -> AXUIElement? {
        let selected = try tabElements(window).filter { (attr($0,"AXValue") as? NSNumber)?.boolValue == true }
        guard selected.count <= 1 else { throw OriginTargetError.unavailable("More than one selected tab is exposed") }
        return selected.first
    }
    private static func isBrowser(_ app: NSRunningApplication) -> Bool {
        let id = app.bundleIdentifier ?? ""
        return ["com.google.Chrome","com.apple.Safari","com.microsoft.edgemac","com.brave.Browser","org.mozilla.firefox","company.thebrowser.Browser","com.operasoftware.Opera","org.chromium.Chromium"].contains { id.lowercased().hasPrefix($0.lowercased()) }
    }
    static func capture(pid: Int32? = nil) throws -> OriginDescriptor {
        guard AXIsProcessTrusted() else { throw OriginTargetError.unavailable("Accessibility permission is required to identify the originating window") }
        guard let app = pid.flatMap({NSRunningApplication(processIdentifier:$0)}) ?? NSWorkspace.shared.frontmostApplication,
              !app.isTerminated, let path=app.bundleURL?.standardizedFileURL.path, let launched=app.launchDate else { throw OriginTargetError.unavailable("The originating app is unavailable") }
        let ax=AXUIElementCreateApplication(app.processIdentifier)
        guard let window=element(ax,"AXFocusedWindow"), (attr(window,"AXMinimized") as? NSNumber)?.boolValue != true else { throw OriginTargetError.unavailable("The originating window is unavailable") }
        let tab=try selectedTab(window)
        guard !isBrowser(app) || tab != nil else { throw OriginTargetError.unavailable("This browser does not expose a stable selected-tab identity") }
        return OriginDescriptor(app_path:path,pid:app.processIdentifier,launch_timestamp:launched.timeIntervalSince1970,
            window_id:try number(window),window_title:attr(window,"AXTitle") as? String ?? "",tab_hash:tab.map(CFHash),captured_at:Date().timeIntervalSince1970)
    }
    init(_ descriptor: OriginDescriptor) throws {
        self.descriptor=descriptor
        guard let app=NSRunningApplication(processIdentifier:descriptor.pid), !app.isTerminated,
              app.bundleURL?.standardizedFileURL.path==descriptor.app_path,
              app.launchDate?.timeIntervalSince1970==descriptor.launch_timestamp else { throw OriginTargetError.unavailable("The originating app has exited or restarted") }
        let ax=AXUIElementCreateApplication(descriptor.pid)
        guard let found=Self.element(ax,"AXFocusedWindow"), try Self.number(found)==descriptor.window_id else { throw OriginTargetError.unavailable("The originating window is no longer selected") }
        window=found
        tab=try Self.selectedTab(found)
        guard tab.map(CFHash)==descriptor.tab_hash else { throw OriginTargetError.unavailable("The originating tab changed before the task started") }
    }
    func checkWindowOnly() throws {
        guard let app=NSRunningApplication(processIdentifier:descriptor.pid), !app.isTerminated,
              app.bundleURL?.standardizedFileURL.path==descriptor.app_path,
              app.launchDate?.timeIntervalSince1970==descriptor.launch_timestamp,
              let current=Self.element(AXUIElementCreateApplication(descriptor.pid),"AXFocusedWindow"),
              try Self.number(current)==descriptor.window_id, CFEqual(current,window) else {
            throw OriginTargetError.unavailable("The originating window changed during tab creation")
        }
    }
    func beginDuplication() throws -> Set<UInt> {
        try check()
        guard let id=NSRunningApplication(processIdentifier:descriptor.pid)?.bundleIdentifier,
              ["com.google.Chrome","org.chromium.Chromium","com.microsoft.edgemac","com.brave.Browser"].contains(where:{id.lowercased().hasPrefix($0.lowercased())}), tab != nil else {
            throw OriginTargetError.unavailable("Controlled tab duplication requires a Chromium browser")
        }
        return Set(try Self.tabElements(window).map(CFHash))
    }
    func restoreAfterDuplication(_ previous: Set<UInt>) throws -> Int {
        try checkWindowOnly()
        let tabs=try Self.tabElements(window)
        let identities=Set(tabs.map(CFHash))
        guard identities.count==previous.count+1, previous.isSubset(of:identities),
              let current=try Self.selectedTab(window), identities.subtracting(previous).contains(CFHash(current)),
              let tab else {
            throw OriginTargetError.unavailable("Could not identify exactly one newly created tab; no existing tab was selected")
        }
        // Restore the retained original AX tab, rather than guessing a tab index or shortcut.
        guard AXUIElementPerformAction(tab,kAXPressAction as CFString) == .success else {
            throw OriginTargetError.unavailable("A tab was created but the originating tab could not be restored")
        }
        return identities.count
    }
    func verifyState(_ result: [String: Any]) throws {
        try check()
        let title=Self.attr(window,"AXTitle") as? String ?? ""
        let app=AXUIElementCreateApplication(descriptor.pid)
        let windows=Self.attr(app,"AXWindows") as? [AXUIElement] ?? []
        guard !title.isEmpty, windows.filter({ Self.attr($0,"AXTitle") as? String == title }).count == 1 else {
            throw OriginTargetError.unavailable("The native response cannot disambiguate windows with this title")
        }
        let text=(result["content"] as? [[String:Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator:"\n")
        let state=text.components(separatedBy:"<app_state>").dropFirst().first ?? ""
        let root=state.components(separatedBy:"\n").first { $0.hasPrefix("0 ") } ?? ""
        guard state.contains("pid \(descriptor.pid)"), root.contains(title) else {
            throw OriginTargetError.unavailable("The native state does not identify the originating window")
        }
    }
    func check(app selector: String? = nil, key: String? = nil) throws {
        if let blocked { throw OriginTargetError.unavailable(blocked) }
        do {
            if let selector, selector.trimmingCharacters(in:CharacterSet(charactersIn:"/")) != descriptor.app_path.trimmingCharacters(in:CharacterSet(charactersIn:"/")) {
                throw OriginTargetError.unavailable("The action requested another application")
            }
            if let key {
                // Native keys cannot select another tab/window or launch another app.
                let normalized=key.lowercased().replacingOccurrences(of:" ",with:"")
                if ["cmd+t","command+t","cmd+n","command+n","cmd+w","command+w","ctrl+tab","control+tab","cmd+`","command+`","cmd+shift+[","cmd+shift+]","cmd+q","command+q"].contains(normalized) {
                    throw OriginTargetError.unavailable("The requested shortcut can change the bound window/tab")
                }
            }
            guard let app=NSRunningApplication(processIdentifier:descriptor.pid), !app.isTerminated,
                  app.bundleURL?.standardizedFileURL.path==descriptor.app_path,
                  app.launchDate?.timeIntervalSince1970==descriptor.launch_timestamp else { throw OriginTargetError.unavailable("The originating app has exited or restarted") }
            let ax=AXUIElementCreateApplication(descriptor.pid)
            guard let current=Self.element(ax,"AXFocusedWindow"), try Self.number(current)==descriptor.window_id,
                  CFEqual(current,window), (Self.attr(current,"AXMinimized") as? NSNumber)?.boolValue != true else {
                throw OriginTargetError.unavailable("The originating window changed or closed")
            }
            let selected=try Self.selectedTab(current)
            guard (tab == nil && selected == nil) || (tab != nil && selected != nil && CFEqual(tab!,selected!)) else {
                throw OriginTargetError.unavailable("The selected tab is no longer the originating tab")
            }
        } catch {
            blocked="Origin verification failed; the task must be resumed explicitly in its original window/tab"
            throw error
        }
    }
}
