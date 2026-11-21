import Foundation

enum SessionFocus {
    static func tty(_ output: String) -> String? {
        var name = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("/dev/") { name.removeFirst(5) }
        else if name.hasPrefix("s"), digits(name.dropFirst()) { name = "tty" + name }
        guard name.hasPrefix("ttys"), digits(name.dropFirst(4)) else { return nil }
        return "/dev/" + name
    }

    private static func digits(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    static func revealURL(_ env: [String: String]) -> URL? {
        if let pane = env["ITERM_SESSION_ID"], !pane.isEmpty {
            var url = URLComponents(string: "iterm2:reveal")!
            url.queryItems = [URLQueryItem(name: "sessionid", value: pane)]
            return url.url
        }
        if let raw = env["WARP_FOCUS_URL"], let url = URL(string: raw), url.scheme == "warp",
           url.host == "session" || (url.host == "action" && url.path.hasPrefix("/focus")) { return url }
        return nil
    }

    static func script(for bundle: String) -> String? {
        let body: String
        switch bundle {
        case "com.apple.Terminal": body = """
            repeat with win in windows
                repeat with targetTab in tabs of win
                    if tty of targetTab is targetTTY then
                        set selected of targetTab to true
                        set index of win to 1
                        activate
                        return
                    end if
                end repeat
            end repeat
            """
        case "com.googlecode.iterm2": body = """
            repeat with win in windows
                repeat with targetTab in tabs of win
                    repeat with targetSession in sessions of targetTab
                        if tty of targetSession is targetTTY then
                            select targetSession
                            select targetTab
                            select win
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end repeat
            """
        case "com.mitchellh.ghostty": body = """
            focus (first terminal whose tty is targetTTY)
            activate
            return
            """
        default: return nil
        }
        return """
        on run argv
            set targetTTY to item 1 of argv
            tell application id "\(bundle)"
                \(body)
            end tell
            error "No matching terminal"
        end run
        """
    }

    static func executable(_ name: String, bundled: String? = nil) -> String? {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":") + ["/opt/homebrew/bin", "/usr/local/bin"]
        return ([bundled].compactMap { $0 } + dirs.filter { $0.hasPrefix("/") }.map { $0 + "/" + name })
            .first(where: FileManager.default.isExecutableFile)
    }

    static func run(_ executable: String, _ arguments: [String]) -> String? {
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
        task.standardInput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice; task.standardOutput = output
        do { try task.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return task.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    static func selectPane(env: [String: String], tty: String?, tmux: String, execute: (String, [String]) -> String? = run) -> Int32? {
        var server: [String] = []
        if let value = env["TMUX"] {
            let fields = value.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, digits(fields.last!), digits(fields[fields.count - 2]), value.hasPrefix("/") else { return nil }
            server = ["-S", fields.dropLast(2).joined(separator: ",")]
        }
        var pane = env["TMUX_PANE"]
        if pane == nil, let tty, let rows = execute(tmux, server + ["list-panes", "-a", "-F", "#{pane_tty} #{pane_id}"]) {
            pane = rows.split(separator: "\n").first { $0.hasPrefix(tty + " ") }?.split(separator: " ").last.map(String.init)
        }
        guard let pane, pane.first == "%", digits(pane.dropFirst()),
              let target = execute(tmux, server + ["display-message", "-p", "-t", pane, "#{session_id}:#{window_id}"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              let session = target.split(separator: ":").first, session.first == "$", digits(session.dropFirst()),
              execute(tmux, server + ["select-window", "-t", target, ";", "select-pane", "-t", pane]) != nil else { return nil }
        let clients = execute(tmux, server + ["list-clients", "-t", String(session), "-F", "#{client_pid}"]) ?? ""
        return clients.split(separator: "\n").first.flatMap { Int32($0) }
    }
}
