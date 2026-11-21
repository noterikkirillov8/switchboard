import Foundation
import os

struct ClaudeAgent: Decodable, Equatable, Sendable {
    let kind: String
    let pid: Int32?
    let cwd: String?
    let sessionId: String?
    let id: String?
    let name: String?
    let status: String?
    let waitingFor: String?
    let state: String?
    let model: String?
    let cliVersion: String?
    let version: String?

    var lineID: String? {
        if let sessionId, !sessionId.isEmpty { return "claude:" + sessionId }
        if let id, !id.isEmpty { return "claude:job:" + id }
        return pid.map { "claude:pid:\($0)" }
    }

    var lineState: LineState? {
        guard kind == "interactive" || kind == "background" else { return nil }
        if kind == "background", let state {
            switch state {
            case "working": return .working
            case "blocked": return .blocked
            case "done": return .done
            case "failed": return .failed
            case "stopped": return .stopped
            default: return nil
            }
        }
        switch status {
        case "busy": return .working
        case "idle": return .done
        case "waiting":
            let reason = waitingFor?.lowercased() ?? ""
            return ["approval", "permission", "sandbox"].contains(where: reason.contains) ? .waitingPermission : .waitingTurn
        default: return nil
        }
    }

    static func parse(_ data: Data) -> [Self]? { try? JSONDecoder().decode([Self].self, from: data) }

    static func poll() -> [Self]? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
            + [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        guard let executable = paths.filter({ $0.hasPrefix("/") }).map({ $0 + "/claude" }).first(where: FileManager.default.isExecutableFile) else { return nil }
        let task = Process(), output = Pipe(), finished = DispatchGroup()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = ["agents", "--json", "--all"]
        task.environment = ProcessInfo.processInfo.environment.merging(["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1"]) { _, new in new }
        task.standardInput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice; task.standardOutput = output
        finished.enter()
        task.terminationHandler = { _ in finished.leave() }
        let deadline = DispatchTime.now() + .seconds(2)
        do { try task.run() } catch { return nil }
        let bytes = OSAllocatedUnfairLock<Data?>(initialState: nil)
        finished.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = try? output.fileHandleForReading.readToEnd()
            bytes.withLock { $0 = data }
            finished.leave()
        }
        guard finished.wait(timeout: deadline) == .success else {
            if task.isRunning { task.terminate() }
            return nil
        }
        guard task.terminationStatus == 0, let data = bytes.withLock({ $0 }) else { return nil }
        return parse(data)
    }
}

