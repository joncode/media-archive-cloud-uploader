import Foundation
import AudioToolbox
import CryptoKit
import Darwin

public struct ArchiveError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct AuthenticationFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// Configuration imports must not load arbitrarily large files or block on pipes/devices.
public enum LocalInput {
    public static func read(_ url: URL, maximumBytes: Int = 65536) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ArchiveError("Cannot read this configuration file. Choose a local, regular file rather than a symbolic link.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maximumBytes else {
            throw ArchiveError("Choose a regular configuration file no larger than 64 KiB.")
        }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ArchiveError("The configuration file is too large.") }
        return data
    }
    public static func text(_ url: URL) throws -> String {
        guard let value = String(data: try read(url), encoding: .utf8) else {
            throw ArchiveError("The configuration file must contain UTF-8 text.")
        }
        return value
    }
}

public struct FileStamp: Codable, Equatable, Sendable {
    public let size: Int64
    let device: Int32
    let inode: UInt64
    let seconds: Int64
    let nanos: Int64
    init(_ s: stat) {
        size = s.st_size; device = s.st_dev; inode = s.st_ino
        seconds = Int64(s.st_mtimespec.tv_sec); nanos = Int64(s.st_mtimespec.tv_nsec)
    }
    public static func read(_ url: URL) throws -> FileStamp {
        var s = stat()
        guard lstat(url.path, &s) == 0, (s.st_mode & S_IFMT) == S_IFREG else {
            throw ArchiveError("The source is missing, unreadable, or is no longer a regular file.")
        }
        return FileStamp(s)
    }
}

public struct AudioItem: Identifiable, Sendable {
    public var id: String { objectName }
    public let url: URL
    public let objectName: String
    public let stamp: FileStamp
    public var size: Int64 { stamp.size }
    public var contentType: String {
        switch url.pathExtension.lowercased() {
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        default: return "audio/mpeg"
        }
    }
    public init(url: URL, objectName: String, stamp: FileStamp) {
        self.url = url; self.objectName = objectName; self.stamp = stamp
    }
    public func openUnchanged() throws -> FileHandle {
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path else {
            throw ArchiveError("A source path changed into a symbolic link. Preview the folder again.")
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ArchiveError("Cannot open the source file. Check that the drive is connected.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try verify(handle) } catch { try? handle.close(); throw error }
        return handle
    }
    public func verify(_ handle: FileHandle) throws {
        var s = stat()
        guard fstat(handle.fileDescriptor, &s) == 0,
              (s.st_mode & S_IFMT) == S_IFREG, FileStamp(s) == stamp,
              try FileStamp.read(url) == stamp else {
            throw ArchiveError("The source changed since preview. Finish recording or editing, then preview again.")
        }
    }
}

public struct ScanReport: Sendable {
    public var items: [AudioItem] = []
    public var excluded: [String] = []
    public var issues: [String] = []
}

public enum AudioScanner {
    public static func scan(folder: URL, includeFolder: Bool) throws -> ScanReport {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              FileManager.default.isReadableFile(atPath: root.path) else {
            throw ArchiveError("The source folder is missing or unreadable. Connect the drive or choose another folder.")
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var report = ScanReport()
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
            options: [], errorHandler: { url, _ in
                report.issues.append("Could not read: \(url.path)"); return true
            }) else { throw ArchiveError("Cannot read the selected folder.") }
        for case let enumeratedURL as URL in walk {
            try Task.checkCancellation()
            // Foundation can enumerate /var as /private/var. Normalize the parent before
            // removing the root; do not resolve the final component, which may be a symlink.
            let url = enumeratedURL.deletingLastPathComponent().resolvingSymlinksInPath()
                .standardizedFileURL.appendingPathComponent(enumeratedURL.lastPathComponent)
            let prefix = root.path == "/" ? "/" : root.path + "/"
            guard url.path.hasPrefix(prefix) else {
                walk.skipDescendants(); report.issues.append("Path escaped the selected folder: \(enumeratedURL.path)"); continue
            }
            let relative = String(url.path.dropFirst(prefix.count))
            do {
                let info = try url.resourceValues(forKeys: Set(keys))
                if info.isSymbolicLink == true || url.lastPathComponent.hasPrefix(".") {
                    walk.skipDescendants(); report.excluded.append(relative + " — hidden or symbolic link"); continue
                }
                if info.isDirectory == true { continue }
                guard info.isRegularFile == true,
                      ["flac", "wav", "mp3"].contains(url.pathExtension.lowercased()) else {
                    report.excluded.append(relative + " — not a supported audio file"); continue
                }
                let name = (includeFolder ? root.lastPathComponent + "/" : "") + relative
                guard name.utf8.count <= 1024, !name.contains("\r"), !name.contains("\n") else {
                    report.issues.append(relative + " — unsupported cloud object name"); continue
                }
                let stamp = try FileStamp.read(url)
                guard stamp.size > 0, isAudio(url) else {
                    report.excluded.append(relative + " — invalid or unreadable audio container"); continue
                }
                report.items.append(AudioItem(url: url, objectName: name, stamp: stamp))
            } catch { report.issues.append(relative + " — " + error.localizedDescription) }
        }
        report.items.sort { $0.objectName < $1.objectName }
        return report
    }

    // The extension alone is not enough: require a matching audio container and nonempty audio data.
    static func isAudio(_ url: URL) -> Bool {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return false }
        defer { AudioFileClose(file) }
        var type: AudioFileTypeID = 0
        var length = UInt32(MemoryLayout<AudioFileTypeID>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyFileFormat, &length, &type) == noErr else { return false }
        let expected: [AudioFileTypeID]
        switch url.pathExtension.lowercased() {
        case "wav": expected = [kAudioFileWAVEType, kAudioFileRF64Type, kAudioFileBW64Type]
        case "flac": expected = [kAudioFileFLACType]
        case "mp3": expected = [kAudioFileMP3Type]
        default: return false
        }
        var count: UInt64 = 0
        length = UInt32(MemoryLayout<UInt64>.size)
        return expected.contains(type) && AudioFileGetProperty(file, kAudioFilePropertyAudioDataByteCount, &length, &count) == noErr && count > 0
    }
}

public struct Digests: Sendable {
    public let md5: String
    public let sha256: String
    public static func read(_ item: AudioItem, handle: FileHandle) throws -> Digests {
        try handle.seek(toOffset: 0)
        var md5 = Insecure.MD5(); var sha = SHA256()
        var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            md5.update(data: data); sha.update(data: data); count += Int64(data.count)
        }
        try item.verify(handle)
        guard count == item.size else { throw ArchiveError("Source length changed while checking the file.") }
        return Digests(md5: Data(md5.finalize()).base64EncodedString(),
                       sha256: Data(sha.finalize()).map { String(format: "%02x", $0) }.joined())
    }
}
