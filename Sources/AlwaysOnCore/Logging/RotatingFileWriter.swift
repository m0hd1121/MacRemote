import Foundation

/// Appends to a file and rotates it at `maxBytes`: `name.log` → `name.log.1` → … → `name.log.<maxFiles-1>`.
/// Files are created with mode 0600 inside a 0700 directory.
public final class RotatingFileWriter {
    public let url: URL
    public let maxBytes: Int
    public let maxFiles: Int
    private var handle: FileHandle?
    private var currentSize: Int = 0
    private let lock = NSLock()

    public init(url: URL, maxBytes: Int, maxFiles: Int) {
        self.url = url
        self.maxBytes = max(maxBytes, 1024)
        self.maxFiles = max(maxFiles, 1)
    }

    deinit {
        try? handle?.close()
    }

    public func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        do {
            if handle == nil { try open() }
            if currentSize + data.count > maxBytes, currentSize > 0 {
                try rotate()
                try open()
            }
            try handle?.write(contentsOf: data)
            currentSize += data.count
        } catch {
            // Logging must never crash the agent. Drop the line and retry opening next time.
            try? handle?.close()
            handle = nil
        }
    }

    public func write(line: String) {
        write(Data((line.hasSuffix("\n") ? line : line + "\n").utf8))
    }

    /// Rotates the file now if it is larger than `maxBytes` (used before handing a file to a child process).
    public static func rotateIfNeeded(url: URL, maxBytes: Int, maxFiles: Int) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > maxBytes else { return }
        try? shift(url: url, maxFiles: maxFiles)
    }

    private func open() throws {
        try FilePermissions.ensurePrivateDirectory(url.deletingLastPathComponent())
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let h = try FileHandle(forWritingTo: url)
        currentSize = Int(try h.seekToEnd())
        handle = h
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        try Self.shift(url: url, maxFiles: maxFiles)
        currentSize = 0
    }

    private static func shift(url: URL, maxFiles: Int) throws {
        let fm = FileManager.default
        let path = url.path
        if maxFiles <= 1 {
            try? fm.removeItem(atPath: path)
            return
        }
        try? fm.removeItem(atPath: "\(path).\(maxFiles - 1)")
        if maxFiles > 2 {
            for index in stride(from: maxFiles - 2, through: 1, by: -1) {
                let from = "\(path).\(index)"
                if fm.fileExists(atPath: from) { try? fm.moveItem(atPath: from, toPath: "\(path).\(index + 1)") }
            }
        }
        if fm.fileExists(atPath: path) { try fm.moveItem(atPath: path, toPath: "\(path).1") }
    }
}

public enum FilePermissions {
    /// Creates `url` (and parents) if needed and tightens it to 0700.
    public static func ensurePrivateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
