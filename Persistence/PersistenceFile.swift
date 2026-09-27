import Foundation

/// Read failures block writes; transient write failures remain retryable.
enum PersistenceStatus: Equatable, Sendable {
    case writable
    case readOnly(String)

    var readError: String? {
        if case let .readOnly(reason) = self { return reason }
        return nil
    }
    var canSave: Bool { self == .writable }
}

/// Disk mechanics only. Stores own validation, migration, and recovery policy.
enum PersistenceFile {
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func save(_ record: some Encodable, to url: URL) throws {
        try write(JSONEncoder().encode(record), to: url)
    }

    @discardableResult
    static func preserve(_ data: Data, in directory: URL, prefix: String) throws -> URL {
        let url = directory.appendingPathComponent("\(prefix)-\(UUID().uuidString).json")
        try write(data, to: url)
        return url
    }
}
