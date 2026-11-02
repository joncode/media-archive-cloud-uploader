import Foundation

/// Non-secret UI selections, stored outside the application bundle and repository.
public struct ArchivePreferences: Codable, Equatable, Sendable {
    public var bucket: String?
    public var projectID: String?
    public var accountEmail: String?
    public var sourceFolder: String?
    public var includeFolder: Bool
    // Optional so settings written by older releases still decode unchanged.
    public var simultaneousUploads: Int?
    public init(bucket: String? = nil, projectID: String? = nil, accountEmail: String? = nil,
                sourceFolder: String? = nil, includeFolder: Bool = false, simultaneousUploads: Int? = nil) {
        self.bucket = bucket; self.projectID = projectID; self.accountEmail = accountEmail
        self.sourceFolder = sourceFolder; self.includeFolder = includeFolder; self.simultaneousUploads = simultaneousUploads
    }
    public static var savedFile: URL { ArchiveConfiguration.savedFile.deletingLastPathComponent().appendingPathComponent("settings.json") }
    public func validate() throws {
        if let simultaneousUploads, ![1, 2, 4].contains(simultaneousUploads) {
            throw ArchiveError("Choose 1, 2, or 4 simultaneous uploads.")
        }
        if let bucket { try ArchiveConfiguration.validateBucket(bucket) }
        if let sourceFolder {
            guard sourceFolder.hasPrefix("/"), !sourceFolder.contains("\0") else { throw ArchiveError("The saved source folder is invalid. Choose it again.") }
        }
    }
    public static func load(from file: URL = savedFile) throws -> ArchivePreferences? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let value = try JSONDecoder().decode(Self.self, from: LocalInput.read(file))
        try value.validate()
        return value
    }
    public func save(to file: URL = Self.savedFile) throws {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= 65536 else { throw ArchiveError("The saved settings are too large.") }
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
