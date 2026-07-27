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
