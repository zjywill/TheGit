import XCTest
@testable import TheGit

/// A child process outlives nobody: cancelling the task that started it, or
/// letting a network command run past its timeout, has to actually kill it.
/// Every git command for a repo runs on one actor, so a process nobody is
/// waiting for any more is a process holding up all the others.
final class ShellLifetimeTests: XCTestCase {

    func testCancellationKillsTheChild() async throws {
        let started = expectation(description: "sleep started")
        let task = Task { () -> String in
            started.fulfill()
            return try await Shell.run("/bin/sh", ["-c", "sleep 30"])
        }
        await fulfillment(of: [started], timeout: 5)
        // The task reports `started` before the process exists, so give the
        // spawn a moment — cancelling earlier than that is the other path
        // (adopt refuses), which is fine but not what this test is for.
        try await Task.sleep(nanoseconds: 300_000_000)

        let began = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled run must not return output")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        // Well under the 30s the child would otherwise take.
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
    }

    func testTimeoutKillsTheChild() async throws {
        let began = Date()
        do {
            _ = try await Shell.run("/bin/sh", ["-c", "sleep 30"], timeout: 0.5)
            XCTFail("a run past its timeout must not return output")
        } catch let error as ShellError {
            XCTAssertTrue(
                error.message.contains("Timed out"),
                "the message has to say what happened: \(error.message)"
            )
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
    }

    /// The timeout is a deadline, not a leash on every command: one that
    /// finishes inside it returns its output like any other.
    func testFastCommandIsUnaffectedByItsTimeout() async throws {
        let out = try await Shell.run("/bin/echo", ["hi"], timeout: 30)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "hi")
    }
}
