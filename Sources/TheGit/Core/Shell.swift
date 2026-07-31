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

    /// Absolute path of an executable, or nil when it isn't installed.
    static func which(_ binary: String) -> String? {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for dir in pathDirs + extraDirs {
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
        let child = ChildProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = args
                    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
                    if !env.isEmpty {
                        process.environment = ProcessInfo.processInfo.environment
                            .merging(env) { _, new in new }
                    }
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

                    let out = String(data: outData, encoding: .utf8) ?? ""
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
                        continuation.resume(throwing: ShellError(
                            command: label ?? args.joined(separator: " "),
                            message: err.isEmpty ? out : err
                        ))
                    case nil:
                        continuation.resume(returning: out)
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
