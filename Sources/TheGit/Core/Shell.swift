import Foundation

struct ShellError: LocalizedError {
    let command: String
    let message: String
    var errorDescription: String? { "\(command): \(message)" }
}

/// Runs external binaries. Everything this app does — git, and the forge
/// CLIs — goes through here, so there is one place that knows how to find
/// a binary and how to run it without it ever trying to talk to a terminal.
enum Shell {
    /// Searched on top of PATH. A double-clicked .app inherits launchd's
    /// bare PATH (/usr/bin:/bin:…), so Homebrew binaries are invisible
    /// unless we go looking for them ourselves.
    private static let extraDirs = [
        "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin",
    ]

    /// What the user's login shell has on PATH, once we've asked it. Empty
    /// until then, which only means `which` searches the two lists above.
    ///
    /// Guesses can't replace this: a Node-managed CLI lives at
    /// ~/.nvm/versions/node/v22.17.0/bin, a path only that user's .zshrc
    /// knows, and installers that drop a binary in ~/.local/bin are now the
    /// norm rather than the exception.
    private static var loginDirs: [String] = []

    /// Asks the user's own shell where things are. One interactive login
    /// shell per launch — interactive because PATH is set in .zshrc far
    /// more often than in .zprofile — so this belongs at startup and
    /// nowhere near a hot path.
    static func resolveLoginPath() async {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return }
        let out = try? await run(
            shell, ["-ilc", "printf '\(pathOpen)%s\(pathClose)' \"$PATH\""],
            label: "\(shell) -ilc printf $PATH"
        )
        guard let dirs = loginPath(from: out ?? ""), !dirs.isEmpty else { return }
        loginDirs = dirs
    }

    // An interactive shell prints things of its own — a motd, a prompt
    // preamble — so the answer is fenced rather than read as the whole of
    // stdout.
    private static let pathOpen = "<TheGitPATH>"
    private static let pathClose = "</TheGitPATH>"

    /// The fenced PATH out of a login shell's chatter, split into
    /// directories. nil when the fence isn't there at all — an empty list
    /// and "the shell never answered" must not be the same thing.
    static func loginPath(from output: String) -> [String]? {
        guard let start = output.range(of: pathOpen),
            let end = output.range(of: pathClose, options: .backwards),
            start.upperBound <= end.lowerBound
        else { return nil }
        return output[start.upperBound..<end.lowerBound]
            .split(separator: ":")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Everywhere a binary might be, in the order we'd rather find it:
    /// what we inherited, then the login shell's PATH, then the usual
    /// install prefixes. Deduplicated — the three lists overlap heavily.
    static func searchDirs() -> [String] {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (pathDirs + loginDirs + extraDirs).filter { seen.insert($0).inserted }
    }

    /// The PATH every child gets. Finding the binary ourselves only covers
    /// the first process: git runs `git-lfs` as its own filter and hook,
    /// `gh` and `glab` shell out to git, and each of those searches PATH.
    /// A double-clicked .app would hand them launchd's bare one and they'd
    /// report a tool missing that the app itself just found.
    static func childPath() -> String { searchDirs().joined(separator: ":") }

    /// Absolute path of an executable, or nil when it isn't installed.
    static func which(_ binary: String) -> String? {
        for dir in searchDirs() {
            let candidate = dir + "/" + binary
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Run to completion off the main thread. Non-zero exit throws with
    /// stderr as the message (falling back to stdout, which is where some
    /// CLIs put their errors).
    ///
    /// Cancelling the calling task kills the child: without that, a
    /// `Task.cancel()` only stops whoever was waiting, while the process
    /// itself runs on holding `GitClient`'s actor — one unreachable remote
    /// and every other git command for that repo queues behind a fetch
    /// nobody is waiting for any more.
    ///
    /// `timeout` is for the commands that talk to a network. Local git is
    /// bounded by the disk and gets none, but a fetch against a host that
    /// accepts the connection and then says nothing has no end of its own.
    @discardableResult
    static func run(
        _ executable: String,
        _ args: [String],
        cwd: String? = nil,
        env: [String: String] = [:],
        label: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> String {
        let data = try await runData(
            executable, args, cwd: cwd, env: env, label: label, timeout: timeout
        )
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Binary-preserving counterpart to `run`, used for Git blobs such as
    /// PNG and WebP files. Error messages are still decoded as text.
    @discardableResult
    static func runData(
        _ executable: String,
        _ args: [String],
        cwd: String? = nil,
        env: [String: String] = [:],
        label: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        let child = ChildProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = args
                    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
                    process.environment = ProcessInfo.processInfo.environment
                        .merging(["PATH": childPath()]) { _, new in new }
                        .merging(env) { _, new in new }
                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    // Cancellation can land before the process exists. Then
                    // there is nothing to start.
                    guard child.adopt(process) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    if let timeout {
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                            child.end(.timedOut)
                        }
                    }

                    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    // Past this point the child is gone, so a late timeout
                    // has nothing to kill and no verdict to give.
                    let ending = child.finish()

                    switch ending {
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    case .timedOut:
                        continuation.resume(throwing: ShellError(
                            command: label ?? args.joined(separator: " "),
                            message: "Timed out after \(Int(timeout ?? 0))s and was stopped."
                        ))
                    case nil where process.terminationStatus != 0:
                        let err = String(data: errData, encoding: .utf8) ?? ""
                        let out = String(data: outData, encoding: .utf8) ?? ""
                        continuation.resume(throwing: ShellError(
                            command: label ?? args.joined(separator: " "),
                            message: err.isEmpty ? out : err
                        ))
                    case nil:
                        continuation.resume(returning: outData)
                    }
                }
            }
        } onCancel: {
            child.end(.cancelled)
        }
    }
}

/// One child process, shared between the queue running it and whoever wants
/// it dead — the cancellation handler, which runs on the caller's thread,
/// and the timeout, which runs on a timer's. All three race, so the whole
/// thing is one lock and the first verdict wins.
private final class ChildProcess: @unchecked Sendable {
    enum Ending { case cancelled, timedOut }

    private let lock = NSLock()
    private var process: Process?
    private var ending: Ending?
    private var done = false

    /// Take ownership of a process about to be started. False when the run
    /// was already called off — the caller must not start it.
    func adopt(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard ending == nil else { return false }
        self.process = process
        return true
    }

    /// Stop the child, if it is still ours to stop. SIGTERM rather than
    /// SIGKILL: git kills its own transport children on the way out, and
    /// killing it outright would leave an ssh holding the pipe open.
    func end(_ reason: Ending) {
        lock.lock()
        defer { lock.unlock() }
        guard !done, ending == nil else { return }
        ending = reason
        if let process, process.isRunning { process.terminate() }
    }

    /// The run is over: report how it ended and close the door on any
    /// verdict arriving afterwards.
    @discardableResult
    func finish() -> Ending? {
        lock.lock()
        defer { lock.unlock() }
        done = true
        process = nil
        return ending
    }
}
