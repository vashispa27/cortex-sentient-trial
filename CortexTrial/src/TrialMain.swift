import Foundation
import Darwin

@main struct TrialMain {
    static func main() async {
        do {
            if let flag = CommandLine.arguments.firstIndex(of: "--capture-origin") {
                let pid = CommandLine.arguments.count > flag+1 ? Int32(CommandLine.arguments[flag+1]) : nil
                let target = try await MainActor.run { try OriginTarget.capture(pid: pid) }
                print(String(decoding: try JSONEncoder().encode(target), as: UTF8.self)); return
            }
            let configuration = try OpenAIComputerUse.Configuration()
            if CommandLine.arguments.contains("--configuration") { print(configuration.codexOverrides); return }
            var origin: OriginTarget?
            if let path = ProcessInfo.processInfo.environment["CORTEX_TRIAL_ORIGIN_FILE"] {
                let descriptor = try JSONDecoder().decode(OriginDescriptor.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                origin = try await MainActor.run { try OriginTarget(descriptor) }
            }
            let server = NativeComputerUseServer(configuration: configuration, origin: origin)
            let connection = try await server.start()
            if CommandLine.arguments.contains("--probe") {
                let response = try await server.respond(JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0", "id":1, "method":"tools/list"]))
                print(String(decoding: response, as: UTF8.self))
                await server.stop()
                return
            }
            let metadata: [String: Any] = ["url": connection.url, "token": connection.token, "overrides": connection.codexOverrides]
            print(String(decoding: try JSONSerialization.data(withJSONObject: metadata), as: UTF8.self))
            fflush(stdout)
            // The parent owns stdin; EOF means stop, including when its model process ends.
            await Task.detached { while readLine() != nil {} }.value
            await server.stop()
        } catch {
            FileHandle.standardError.write(Data("Native trial failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
