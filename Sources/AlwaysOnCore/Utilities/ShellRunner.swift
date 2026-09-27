import Foundation

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public var succeeded: Bool { status == 0 && !timedOut }
}

public enum CommandError: Error, CustomStringConvertible {
    case notExecutable(String)
    case launchFailed(String)

    public var description: String {
        switch self {
        case .notExecutable(let path): return "\(path) is not an executable file"
        case .launchFailed(let message): return "launch failed: \(message)"
        }
    }
}

/// Runs an external program with an explicit argv. There is deliberately no API that takes a
/// shell string: nothing user-controlled is ever interpolated into `/bin/sh -c`.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], stdin: Data?, timeout: TimeInterval) throws -> CommandResult
}

extension CommandRunning {
    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 15) throws -> CommandResult {
        try run(executable, arguments, stdin: nil, timeout: timeout)
    }
}

public struct ShellRunner: CommandRunning {
    /// Environment for child processes: a fixed PATH and locale so output parsing is stable.
    public var environment: [String: String]

    public init(environment: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]) {
        self.environment = environment
    }

    public func run(_ executable: String, _ arguments: [String], stdin: Data?, timeout: TimeInterval) throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw CommandError.notExecutable(executable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = stdin == nil ? nil : Pipe()
        if let inPipe {
            process.standardInput = inPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed(error.localizedDescription)
        }

        // Drain both pipes concurrently so a chatty child cannot block on a full pipe buffer.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let ioQueue = DispatchQueue.global(qos: .utility)
        group.enter()
        ioQueue.async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        ioQueue.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if let inPipe, let stdin {
            ioQueue.async {
                try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? inPipe.fileHandleForWriting.close()
            }
        }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
        }
        _ = group.wait(timeout: .now() + 5)

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            timedOut: timedOut
        )
    }
}
