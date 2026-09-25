import Darwin
import Foundation

protocol BatteryCommandRunning: Sendable {
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> Data
}

enum BatteryCommandError: Error, Equatable {
    case invalidExecutable
    case nonZeroExit(Int32)
    case timedOut
    case outputLimitExceeded
    case outputReadFailed
}

/// Runs only an absolute executable, never a shell. All blocking Foundation/POSIX
/// work runs on a utility queue, including launching and reaping the subprocess.
struct BatteryCommandRunner: BatteryCommandRunning {
    let maximumOutputBytes: Int
    let terminationGrace: TimeInterval

    init(maximumOutputBytes: Int = 2 * 1_024 * 1_024, terminationGrace: TimeInterval = 0.15) {
        self.maximumOutputBytes = max(0, maximumOutputBytes)
        self.terminationGrace = terminationGrace.isFinite ? max(0, terminationGrace) : 0.15
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        let cancellation = CommandCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let output: Data = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let output = try execute(
                            executable: executable, arguments: arguments,
                            timeout: timeout, cancellation: cancellation
                        )
                        continuation.resume(returning: output)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
            return output
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func execute(
        executable: String, arguments: [String], timeout: TimeInterval,
        cancellation: CommandCancellation
    ) throws -> Data {
        try cancellation.check()
        guard executable.hasPrefix("/") else { throw BatteryCommandError.invalidExecutable }
        guard timeout.isFinite, timeout > 0 else { throw BatteryCommandError.timedOut }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let process = Process()
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        // Diagnostics are not battery data; never let an unread stderr pipe fill up.
        process.standardError = FileHandle.nullDevice

        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw BatteryCommandError.outputReadFailed
        }
        try cancellation.launch(process)
        try? pipe.fileHandleForWriting.close()

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        var reachedEOF = false
        var hasExited = false
        do {
            while true {
                try cancellation.check()
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw BatteryCommandError.timedOut
                }
                // Drain while the child is running, not after waitUntilExit().
                // Nonblocking reads also handle children that never close stdout.
                while !reachedEOF {
                    try cancellation.check()
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw BatteryCommandError.timedOut
                    }
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.read(descriptor, $0.baseAddress, $0.count)
                    }
                    if count > 0 {
                        guard count <= maximumOutputBytes - output.count else {
                            throw BatteryCommandError.outputLimitExceeded
                        }
                        output.append(contentsOf: buffer.prefix(count))
                    } else if count == 0 {
                        reachedEOF = true
                    } else if errno == EINTR {
                        continue
                    } else if errno == EAGAIN || errno == EWOULDBLOCK {
                        break
                    } else {
                        throw BatteryCommandError.outputReadFailed
                    }
                }
                if hasExited {
                    // A descendant may inherit stdout. Once the direct child
                    // exits and buffered data is drained, do not wait for its EOF.
                    try cancellation.check()
                    guard process.terminationStatus == 0 else {
                        throw BatteryCommandError.nonZeroExit(process.terminationStatus)
                    }
                    return output
                }
                if !process.isRunning {
                    hasExited = true
                    // Drain again: bytes may have arrived between the last read
                    // and observing termination.
                    continue
                }
                if reachedEOF {
                    Thread.sleep(forTimeInterval: 0.01)
                } else {
                    var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                    _ = poll(&event, 1, 10)
                }
            }
        } catch {
            stop(process)
            throw error
        }
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + terminationGrace
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        // Only the direct child is reaped; inherited pipes never gate completion.
        process.waitUntilExit()
    }
}

/// The worker exclusively owns Process and its file descriptors. The cancellation
/// handler only touches this lock-protected flag, avoiding termination-handler
/// retain cycles and concurrent reads/closes of FileHandle.
private final class CommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.withLock { isCancelled = true }
    }

    func check() throws {
        try lock.withLock {
            if isCancelled { throw CancellationError() }
        }
    }

    func launch(_ process: Process) throws {
        try lock.withLock {
            if isCancelled { throw CancellationError() }
            // Serialize the last cancellation check with launch, so cancellation
            // already received cannot launch another helper.
            try process.run()
        }
    }
}
