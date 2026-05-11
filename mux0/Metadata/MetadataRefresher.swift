import Foundation

final class MetadataRefresher {
    private let metadata: WorkspaceMetadata
    /// Closure that resolves the workspace's current working directory. Re-evaluated
    /// on every tick because pwd tracks the focused terminal's shell cwd
    /// (ghostty `GHOSTTY_ACTION_PWD` → `TerminalPwdStore`), which moves with `cd`.
    /// Returning nil — e.g. no shell has reported pwd yet — skips the git probe
    /// entirely so we don't run `git` from an unrelated dir.
    private let workingDirectoryProvider: () -> String?
    private var timer: Timer?
    var onRefresh: (() -> Void)?

    init(metadata: WorkspaceMetadata, workingDirectoryProvider: @escaping () -> String?) {
        self.metadata = metadata
        self.workingDirectoryProvider = workingDirectoryProvider
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Run one probe cycle now. Safe to call on main thread; work hops to a
    /// background queue and results are published back on main.
    func refresh() {
        let dir = workingDirectoryProvider()
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            let branch = dir.flatMap { self.fetchGitBranch(cwd: $0) }
            // Only fetch diff stats when we have a branch — saves a process
            // spawn per tick on non-git dirs (the cwd → no-repo fast-fail
            // case from `git rev-parse` already short-circuited above).
            let diff: (added: Int, deleted: Int)? = (branch != nil && dir != nil)
                ? self.fetchGitDiffStats(cwd: dir!)
                : nil
            DispatchQueue.main.async {
                self.metadata.workingDirectory = dir
                self.metadata.gitBranch = branch
                self.metadata.gitDiffAdded = diff?.added
                self.metadata.gitDiffDeleted = diff?.deleted
                self.onRefresh?()
            }
        }
    }

    private func fetchGitBranch(cwd: String) -> String? {
        let output = shell("git rev-parse --abbrev-ref HEAD", cwd: cwd)
        return MetadataRefresher.parseBranch(from: output ?? "")
    }

    /// `git diff --shortstat HEAD` returns one summary line aggregating staged
    /// + unstaged tracked changes against the last commit. Untracked files are
    /// not counted (matches VS Code's source-control gutter math).
    private func fetchGitDiffStats(cwd: String) -> (added: Int, deleted: Int)? {
        let output = shell("git diff --shortstat HEAD", cwd: cwd)
        return MetadataRefresher.parseShortstat(from: output ?? "")
    }

    private func shell(_ command: String, cwd: String?) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    // MARK: - Parsers (static for testability)

    static func parseBranch(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parse `git diff --shortstat HEAD`'s single line into (added, deleted).
    /// Returns nil when the line is empty (no changes). Examples:
    ///   ` 3 files changed, 47 insertions(+), 12 deletions(-)`
    ///   ` 1 file changed, 5 insertions(+)`              — only adds
    ///   ` 2 files changed, 9 deletions(-)`              — only dels
    ///   ``                                              — clean
    /// Outside a git repo `shell` returns empty stdout so we land in the
    /// clean branch and return nil — caller treats that as "no info".
    static func parseShortstat(from output: String) -> (added: Int, deleted: Int)? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var added = 0
        var deleted = 0
        for chunk in trimmed.split(separator: ",") {
            let s = chunk.trimmingCharacters(in: .whitespaces)
            // Each chunk begins with the count: "47 insertions(+)" / "12 deletions(-)".
            // Files chunk ("3 files changed") is ignored.
            guard let firstToken = s.split(separator: " ").first,
                  let n = Int(firstToken) else { continue }
            if s.contains("insertion") { added = n }
            else if s.contains("deletion") { deleted = n }
        }
        return (added, deleted)
    }
}
