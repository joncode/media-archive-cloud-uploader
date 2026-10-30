import Foundation

public struct ArchiveConfiguration: Equatable, Sendable {
    public let bucket: String
    public let sourceFolder: URL?

    public init(environment: [String: String], fileValues: [String: String] = [:]) throws {
        let values = fileValues.merging(environment) { _, processValue in processValue }
        let bucket = values["BISCO_GCS_BUCKET"] ?? ""
        try Self.validateBucket(bucket)
        self.bucket = bucket
        let source = values["BISCO_SOURCE_FOLDER"] ?? ""
        if source.isEmpty { sourceFolder = nil }
        else {
            let expanded = (source as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/"), !expanded.contains("\0"), !expanded.contains("\n") else {
                throw ArchiveError("BISCO_SOURCE_FOLDER must be an absolute folder path, or empty to use the folder picker.")
            }
            sourceFolder = URL(fileURLWithPath: expanded, isDirectory: true)
        }
    }

    public static func validateBucket(_ bucket: String) throws {
        guard (3...222).contains(bucket.utf8.count),
              bucket.range(of: "^[a-z0-9][a-z0-9._-]*[a-z0-9]$", options: .regularExpression) != nil,
              bucket.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.count <= 63 }) else {
            throw ArchiveError("Set BISCO_GCS_BUCKET to your bucket name in the environment or import a local .env configuration. Use only the bucket name, without gs:// or a folder path.")
        }
    }

    // A literal key/value file, never a shell script. No variable or command expansion.
    public static func parse(_ text: String) throws -> [String: String] {
        guard text.utf8.count <= 65536 else { throw ArchiveError("The environment configuration file is too large.") }
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let equal = line.firstIndex(of: "=") else { throw ArchiveError("Use KEY=value lines in the .env configuration.") }
            let key = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
            guard ["BISCO_GCS_BUCKET", "BISCO_SOURCE_FOLDER"].contains(key) else {
                throw ArchiveError("The .env file accepts only BISCO_GCS_BUCKET and BISCO_SOURCE_FOLDER.")
            }
            guard values[key] == nil else { throw ArchiveError("The .env configuration contains a duplicate key.") }
            var value = String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
            if value.first == "\"" || value.first == "'" {
                guard value.count >= 2, value.last == value.first else { throw ArchiveError("The .env configuration has an unmatched quote.") }
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }

    public static var savedFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bisco Archive Uploader", isDirectory: true).appendingPathComponent(".env")
    }
    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ArchiveConfiguration {
        let file: URL
        if let explicit = environment["BISCO_ENV_FILE"], !explicit.isEmpty {
            let path = (explicit as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { throw ArchiveError("BISCO_ENV_FILE must be an absolute file path.") }
            file = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: file.path) else { throw ArchiveError("BISCO_ENV_FILE does not exist.") }
        } else { file = savedFile }
        var values: [String: String] = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            values = try parse(LocalInput.text(file))
        }
        return try ArchiveConfiguration(environment: environment, fileValues: values)
    }
    public static func saveImported(_ text: String, to file: URL = savedFile) throws {
        let values = try parse(text)
        _ = try ArchiveConfiguration(environment: [:], fileValues: values)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Protect the directory before creating/replacing the file, including on an existing install.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.deletingLastPathComponent().path)
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
