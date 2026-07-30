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

    /// Absolute path of an executable, or nil when it isn't installed.
    static func which(_ binary: String) -> String? {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for dir in pathDirs + loginDirs + extraDirs {
            let candidate = dir + "/" + binary
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Run to completion off the main thread. Non-zero exit throws with
    /// stderr as the message (falling back to stdout, which is where some
    /// CLIs put their errors).
    @discardableResult
    static func run(
        _ executable: String,
        _ args: [String],
        cwd: String? = nil,
        env: [String: String] = [:],
        label: String? = nil
    ) async throws -> String {
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
                    continuation.resume(throwing: ShellError(
                        command: label ?? args.joined(separator: " "),
                        message: err.isEmpty ? out : err
                    ))
                } else {
                    continuation.resume(returning: out)
                }
            }
        }
    }
}
