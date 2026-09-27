import Foundation

public enum JSONCoding {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

public enum AtomicFile {
    /// Writes via a temp file + rename so readers never see partial content. Mode is applied
    /// to the temp file before the rename.
    public static func write(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: permissions]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path])
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}

public struct ConfigLoadResult {
    public var configuration: AppConfiguration
    public var notes: [String]
}

/// Loads and saves `config.json` (mode 0600 inside a 0700 directory).
public struct ConfigStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// A missing file yields defaults (and writes them). A corrupt file is preserved as
    /// `config.json.corrupt-<timestamp>` and defaults are used, so the agent always starts.
    public func load() throws -> ConfigLoadResult {
        try FilePermissions.ensurePrivateDirectory(url.deletingLastPathComponent())
        guard FileManager.default.fileExists(atPath: url.path) else {
            let config = AppConfiguration()
            try save(config)
            return ConfigLoadResult(configuration: config, notes: ["Created default configuration."])
        }
        let data = try Data(contentsOf: url)
        do {
            var config = try JSONCoding.decoder().decode(AppConfiguration.self, from: data)
            let notes = config.sanitize()
            return ConfigLoadResult(configuration: config, notes: notes)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = url.deletingLastPathComponent().appendingPathComponent("config.json.corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: url, to: backup)
            let config = AppConfiguration()
            try save(config)
            return ConfigLoadResult(configuration: config,
                                    notes: ["Configuration was unreadable (\(error)); saved as \(backup.lastPathComponent) and reset to defaults."])
        }
    }

    public func save(_ configuration: AppConfiguration) throws {
        try FilePermissions.ensurePrivateDirectory(url.deletingLastPathComponent())
        var copy = configuration
        copy.sanitize()
        let data = try JSONCoding.encoder(pretty: true).encode(copy)
        try AtomicFile.write(data, to: url, permissions: 0o600)
    }
}
