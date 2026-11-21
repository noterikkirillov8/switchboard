import Foundation

/// `Switchboard -demo`: fictional sessions for filming. Nothing real is read and nothing real is written.
@MainActor
enum FilmDemo {
    static let on = CommandLine.arguments.contains("-demo")
    /// A throwaway suite: wiped at launch, so no real preference is read or changed.
    static let defaults: UserDefaults = {
        let d = UserDefaults(suiteName: "switchboard.demo")!
        d.removePersistentDomain(forName: "switchboard.demo")
        return d
    }()

    static func lines(now: Date = Date()) -> [Line] {
        func ln(_ name: String, _ tool: Tool, _ model: String, _ cli: String, _ repo: String, _ branch: String, _ mins: Double, _ act: [Int], worktree: Bool = false) -> Line {
            Line(id: "demo:" + name, tool: tool, cwd: "/demo/" + name, model: model, cliVersion: cli, git: GitLabel(repo: repo, branch: branch, worktree: worktree),
                 state: .working, since: now.addingTimeInterval(-mins * 60), activity: act, pid: 1, observedAt: now)
        }
        return [ln("storefront", .claude, "Opus 5.5", "2.1.0", "storefront", "feat/checkout", 14, [2, 5, 4, 9, 7, 3, 6, 11, 8, 5, 9, 12]),
                ln("landing-page", .codex, "gpt-5", "0.92.0", "landing-page", "main", 6, [0, 3, 5, 2, 6, 4, 8, 5, 3, 7, 4, 6]),
                ln("api-server", .claude, "Sonnet 5.5", "2.1.0", "api-server", "fix/rate-limit", 9, [4, 6, 3, 8, 5, 7, 9, 4, 6, 10, 7, 8]),
                ln("orbit-ios", .claude, "Sonnet 5.5", "2.1.0", "orbit", "feat/widgets", 22, [1, 3, 2, 5, 4, 6, 3, 2, 5, 4, 7, 3], worktree: true),
                ln("docs", .codex, "gpt-5", "0.92.0", "docs", "main", 3, [0, 1, 0, 2, 1, 3, 2, 1, 4, 2, 1, 2])]
    }
}
