import Foundation

struct GitError: LocalizedError {
    let command: String
    let message: String
    var errorDescription: String? { "git \(command): \(message)" }
}

/// Thin wrapper around the system `git` binary. All mutations go through here,
/// serialized by the actor so we never run two writing commands concurrently.
actor GitClient {
    let repoPath: String

    init(repoPath: String) {
        self.repoPath = repoPath
    }

    @discardableResult
    func run(_ args: [String]) async throws -> String {
        let path = repoPath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["git", "-C", path] + args
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                let out = String(data: outData, encoding: .utf8) ?? ""
                if process.terminationStatus != 0 {
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    continuation.resume(throwing: GitError(
                        command: args.joined(separator: " "),
                        message: err.isEmpty ? out : err
                    ))
                } else {
                    continuation.resume(returning: out)
                }
            }
        }
    }

    // MARK: - Queries

    func log(limit: Int = 300) async throws -> [Commit] {
        // hash, parents, author, unix-date, refs, subject — tab separated, subject last.
        let format = "%H%x09%P%x09%an%x09%at%x09%D%x09%s"
        let out = try await run([
            // --date-order interleaves parallel branches chronologically
            // (GitKraken-style) while still keeping children before parents.
            "log", "--date-order", "--branches", "--remotes", "--tags", "HEAD",
            "--format=\(format)", "-n", String(limit),
        ])
        return GitParsers.parseLog(out)
    }

    func branches() async throws -> (local: [Branch], remote: [Branch]) {
        let out = try await run([
            "for-each-ref",
            "--format=%(refname)%09%(HEAD)",
            "refs/heads", "refs/remotes",
        ])
        return GitParsers.parseBranches(out)
    }

    func worktrees() async throws -> [Worktree] {
        let out = try await run(["worktree", "list", "--porcelain"])
        return GitParsers.parseWorktrees(out)
    }

    func status() async throws -> (staged: [FileChange], unstaged: [FileChange], branch: String?) {
        let out = try await run(["status", "--porcelain=v2", "--branch"])
        return GitParsers.parseStatus(out)
    }

    // MARK: - Mutations

    func stage(_ path: String) async throws {
        try await run(["add", "--", path])
    }

    func stageAll() async throws {
        try await run(["add", "-A"])
    }

    func unstage(_ path: String) async throws {
        try await run(["reset", "-q", "HEAD", "--", path])
    }

    func unstageAll() async throws {
        try await run(["reset", "-q", "HEAD"])
    }

    func commit(message: String) async throws {
        try await run(["commit", "-m", message])
    }

    func checkout(branch: String) async throws {
        try await run(["checkout", branch])
    }

    /// Checkout a remote branch as a new local tracking branch (or switch if it exists).
    func checkoutRemote(_ branch: Branch) async throws {
        guard case .remote = branch.kind else {
            try await checkout(branch: branch.name)
            return
        }
        // `git checkout <shortName>` DWIMs a tracking branch when unambiguous.
        try await run(["checkout", branch.shortName])
    }

    func fetch() async throws {
        try await run(["fetch", "--all", "--prune"])
    }

    func pull() async throws {
        try await run(["pull"])
    }

    func push() async throws {
        try await run(["push"])
    }
}
