import Darwin
import Foundation
import XCTest
@testable import Clocky

final class BatteryCommandRunnerTests: XCTestCase {
    func testCapturesStandardOutput() async throws {
        let data = try await BatteryCommandRunner().run(
            executable: "/bin/sh", arguments: ["-c", "printf '42\\n'"], timeout: 2
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "42\n")
    }

    func testArgumentsArePassedLiterally() async throws {
        let argument = "$(touch should-not-exist); quoted ' argument"
        let data = try await BatteryCommandRunner().run(
            executable: "/bin/echo", arguments: [argument], timeout: 2
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), argument + "\n")
    }

    func testNonzeroExitDiscardsOtherwiseValidOutput() async {
        do {
            _ = try await BatteryCommandRunner().run(
                executable: "/bin/sh", arguments: ["-c", "printf 80; exit 7"], timeout: 2
            )
            XCTFail("Expected unsuccessful exit")
        } catch {
            XCTAssertEqual(error as? BatteryCommandError, .nonZeroExit(7))
        }
    }

    func testRelativeExecutableIsRejected() async {
        do {
            _ = try await BatteryCommandRunner().run(executable: "echo", arguments: [], timeout: 2)
            XCTFail("Expected absolute-path requirement")
        } catch {
            XCTAssertEqual(error as? BatteryCommandError, .invalidExecutable)
        }
    }

    func testMissingExecutableFailsWithoutHanging() async {
        do {
            _ = try await BatteryCommandRunner().run(
                executable: "/nonexistent-clocky-test/ideviceinfo", arguments: [], timeout: 2
            )
            XCTFail("Expected launch failure")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testDrainsOutputLargerThanPipeCapacity() async throws {
        let data = try await BatteryCommandRunner(maximumOutputBytes: 1_024 * 1_024).run(
            executable: "/bin/sh",
            arguments: ["-c", "exec /bin/dd if=/dev/zero bs=65536 count=8"], timeout: 3
        )
        XCTAssertEqual(data.count, 524_288)
        XCTAssertTrue(data.allSatisfy { $0 == 0 })
    }

    func testLargeStderrDoesNotFillAnUnreadPipe() async throws {
        let data = try await BatteryCommandRunner().run(
            executable: "/bin/sh",
            arguments: ["-c", "exec /bin/dd if=/dev/zero bs=65536 count=8 >&2"], timeout: 3
        )
        XCTAssertTrue(data.isEmpty)
    }

    func testTimeoutKillsChildThatIgnoresTermination() async throws {
        let marker = temporaryMarker()
        defer { try? FileManager.default.removeItem(at: marker) }
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await BatteryCommandRunner(terminationGrace: 0.05).run(
                executable: "/bin/sh", arguments: stubbornChild(marker), timeout: 0.2
            )
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? BatteryCommandError, .timedOut)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        try assertChildStopped(marker)
    }

    func testCancellationKillsInflightChild() async throws {
        let marker = temporaryMarker()
        defer { try? FileManager.default.removeItem(at: marker) }
        let arguments = stubbornChild(marker)
        let task = Task {
            try await BatteryCommandRunner(terminationGrace: 0.05).run(
                executable: "/bin/sh", arguments: arguments, timeout: 10
            )
        }
        defer { task.cancel() }
        try await waitForMarker(marker)
        let start = ProcessInfo.processInfo.systemUptime
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        try assertChildStopped(marker)
    }

    func testCancellationBeforeRunNeverLaunches() async {
        let marker = temporaryMarker()
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await BatteryCommandRunner().run(
                executable: "/bin/sh", arguments: ["-c", "printf launched > \"$1\"", "fixture", marker.path],
                timeout: 2
            )
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testExcessiveOutputIsBoundedAndChildIsStopped() async throws {
        let marker = temporaryMarker()
        defer { try? FileManager.default.removeItem(at: marker) }
        do {
            _ = try await BatteryCommandRunner(maximumOutputBytes: 4_096, terminationGrace: 0.05).run(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; echo $$ > \"$1\"; while :; do printf '0123456789abcdef'; done", "fixture", marker.path],
                timeout: 3
            )
            XCTFail("Expected output limit")
        } catch {
            XCTAssertEqual(error as? BatteryCommandError, .outputLimitExceeded)
        }
        try assertChildStopped(marker)
    }

    func testClosedStdoutDoesNotBypassTimeout() async {
        do {
            _ = try await BatteryCommandRunner(terminationGrace: 0.02).run(
                executable: "/bin/sh", arguments: ["-c", "exec 1>&-; trap '' TERM; while :; do :; done"],
                timeout: 0.1
            )
            XCTFail("Expected timeout even after EOF")
        } catch {
            XCTAssertEqual(error as? BatteryCommandError, .timedOut)
        }
    }

    @MainActor
    func testWaitingForCommandDoesNotBlockMainActor() async throws {
        let task = Task {
            try await BatteryCommandRunner().run(
                executable: "/bin/sh", arguments: ["-c", "exec /bin/sleep 2"], timeout: 3
            )
        }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(20))
        // If the command blocked MainActor, it would already have succeeded
        // before this actor could cancel it. Avoid a tight wall-clock assertion.
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("MainActor could not cancel a running command")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func temporaryMarker() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Clocky-process-\(UUID().uuidString)")
    }

    private func stubbornChild(_ marker: URL) -> [String] {
        ["-c", "trap '' TERM; echo $$ > \"$1\"; while :; do :; done", "fixture", marker.path]
    }

    private func waitForMarker(_ marker: URL) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let contents = try? String(contentsOf: marker, encoding: .utf8),
               Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Fixture never launched")
        throw BatteryCommandError.timedOut
    }

    private func assertChildStopped(_ marker: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try String(contentsOf: marker, encoding: .utf8)
        let pid = try XCTUnwrap(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), file: file, line: line)
        let result = Darwin.kill(pid, 0)
        let failure = errno
        XCTAssertEqual(result, -1, "Child must not survive completion", file: file, line: line)
        XCTAssertEqual(failure, ESRCH, file: file, line: line)
    }
}
