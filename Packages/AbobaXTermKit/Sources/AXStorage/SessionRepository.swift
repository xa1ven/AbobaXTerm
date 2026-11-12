import AXL10n
import AXModels
import Foundation

/// Reads and writes the session library as JSON.
///
/// Writes are atomic, and the previous file is kept as `sessions.json.bak`.
/// Methods are synchronous; callers move them off the main thread when needed.
public struct SessionRepository: Sendable {
    public enum LoadError: Error, LocalizedError {
        /// The file exists but could not be decoded. It was copied to `backupURL`.
        case corrupted(backupURL: URL, underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .corrupted(let url, let error):
                L("sessions.json could not be read (%1$@). A copy was saved to %2$@.", error.localizedDescription, url.path)
            }
        }
    }

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> SessionLibrary {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return SessionLibrary() }
        let data = try Data(contentsOf: fileURL)
        do {
            return try Self.decoder.decode(SessionLibrary.self, from: data)
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
            try? fm.copyItem(at: fileURL, to: backup)
            throw LoadError.corrupted(backupURL: backup, underlying: error)
        }
    }

    public func save(_ library: SessionLibrary) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(library)
        if fm.fileExists(atPath: fileURL.path) {
            let backup = fileURL.appendingPathExtension("bak")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: fileURL, to: backup)
        }
        try data.write(to: fileURL, options: [.atomic])
    }

    private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainStyle = Date.ISO8601FormatStyle()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(fractionalStyle))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            if let date = try? fractionalStyle.parse(text) { return date }
            if let date = try? plainStyle.parse(text) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid date: \(text)")
        }
        return d
    }()
}
