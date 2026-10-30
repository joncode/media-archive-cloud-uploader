import Foundation
import CryptoKit

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public final class SecureHTTP: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    // The separate delegate prevents a URLSession -> client -> URLSession retain cycle.
    // Redirects are refused so tokens and resumable capabilities stay on their original host.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ArchiveError("Invalid server response.") }
            return (data, response)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // URLSession errors may contain the secret resumable URI. Do not surface them.
            if let e = error as? URLError { throw NetworkFailure(code: e.code.rawValue) }
            throw error
        }
    }
}

public struct NetworkFailure: LocalizedError {
    public let code: Int
    public var errorDescription: String? { "Connection interrupted (network error \(code)). Retry when connected." }
}

public struct ServiceFailure: LocalizedError {
    public let status: Int
    public init(status: Int) { self.status = status }
    public var errorDescription: String? {
        switch status {
        case 401: return "Google login expired. Sign in again, then retry."
        case 403: return "Google denied access. Ask the bucket administrator to check your account’s create/get permissions and OAuth access."
        case 400: return "Google rejected the request or checksum. Preview the source again; check the project and bucket configuration."
        case 404: return "Bucket or upload session not found. Check access and retry."
        case 429: return "Google is limiting requests. Wait a moment, then retry."
        default: return "Google returned HTTP \(status). Retry; contact the administrator if it persists."
        }
    }
    var retryable: Bool { status == 408 || status == 429 || (500...599).contains(status) }
}

public protocol SecretStore: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ key: String, data: Data) throws
    func remove(_ key: String) throws
    func clearUploads() throws
}

public struct UploadCheckpoint: Codable, Sendable {
    let session: URL
    let digest: String
    let size: Int64
    let created: Date
}

public enum UploadResult: String, Sendable { case uploaded = "Uploaded", existing = "Skipped — already exists" }
public struct UploadProgress: Sendable {
    public let bytes: Int64
    public let message: String
}

public actor StorageClient {
    public let bucket: String
    public static let chunkSize = 8 * 1024 * 1024
    private let http: HTTPTransport
    private let store: SecretStore
    private let token: @Sendable (Bool) async throws -> String
    private let delay: @Sendable (Int) async throws -> Void

    public init(bucket: String, http: HTTPTransport = SecureHTTP(), store: SecretStore,
                token: @escaping @Sendable (Bool) async throws -> String,
                delay: @escaping @Sendable (Int) async throws -> Void = { attempt in
                    try await Task.sleep(nanoseconds: UInt64((pow(2, Double(attempt)) + Double.random(in: 0...1)) * 1e9))
                }) throws {
        try ArchiveConfiguration.validateBucket(bucket)
        self.bucket = bucket
        self.http = http; self.store = store; self.token = token; self.delay = delay
    }

    public func objectURL(_ name: String) -> URL {
        let escaped = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return URL(string: "https://storage.googleapis.com/storage/v1/b/\(bucket)/o/\(escaped)?fields=name,size,md5Hash,generation")!
    }
    public func initiationURL(_ name: String) -> URL {
        var c = URLComponents(string: "https://storage.googleapis.com/upload/storage/v1/b/\(bucket)/o")!
        c.queryItems = [URLQueryItem(name: "uploadType", value: "resumable"),
                       URLQueryItem(name: "name", value: name), URLQueryItem(name: "ifGenerationMatch", value: "0")]
        // '+' is legal in RFC 3986 queries, but form-style query parsers treat it as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }
    public func validSession(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "storage.googleapis.com" && url.user == nil && url.password == nil &&
        (url.port == nil || url.port == 443) && url.path == "/upload/storage/v1/b/\(bucket)/o" &&
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "upload_id" && !($0.value ?? "").isEmpty }) == true
    }
    private func authorized(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        for refresh in [false, true] {
            try Task.checkCancellation()
            var req = request
            req.setValue("Bearer " + (try await token(refresh)), forHTTPHeaderField: "Authorization")
            let result = try await http.send(req)
            if result.1.statusCode != 401 || refresh { return result }
        }
        throw ServiceFailure(status: 401)
    }
    public func exists(_ item: AudioItem) async throws -> Bool {
        for attempt in 0..<5 {
            do {
                let (_, response) = try await authorized(URLRequest(url: objectURL(item.objectName)))
                switch response.statusCode {
                case 200: return true
                case 404: return false
                default: throw ServiceFailure(status: response.statusCode)
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard attempt < 4, isRetryable(error) else { throw error }
                try await delay(attempt)
            }
        }
        throw ArchiveError("Could not check destination.")
    }
    private func checkpointKey(_ item: AudioItem) -> String {
        "upload-" + SHA256.hash(data: Data((bucket + "\n" + item.objectName + "\n" + item.url.path).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    private func isRetryable(_ error: Error) -> Bool {
        error is NetworkFailure || (error as? ServiceFailure)?.retryable == true
    }
    private func completed(_ data: Data, item: AudioItem, digest: Digests) throws {
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard obj?["name"] as? String == item.objectName,
              obj?["size"] as? String == String(item.size), obj?["md5Hash"] as? String == digest.md5 else {
            throw ArchiveError("Upload completion could not be verified. The object may exist; ask the administrator to inspect its size and checksum before treating it as archived.")
        }
    }
    public static func acknowledgedOffset(_ response: HTTPURLResponse, total: Int64) throws -> Int64 {
        guard let range = response.value(forHTTPHeaderField: "Range") else { return 0 }
        guard range.hasPrefix("bytes=0-"), let last = Int64(range.dropFirst(8)), last >= 0, last < total else {
            throw ArchiveError("Google returned an invalid resumable upload range.")
        }
        return last + 1
    }

    public func upload(_ item: AudioItem, progress: @escaping @Sendable (UploadProgress) async -> Void) async throws -> UploadResult {
        try Task.checkCancellation()
        let key = checkpointKey(item)
        if try await exists(item) { try store.remove(key); return .existing }
        await progress(UploadProgress(bytes: 0, message: "Checking file integrity…"))
        let handle = try item.openUnchanged()
        defer { try? handle.close() }
        let digest = try Digests.read(item, handle: handle)
        var checkpoint: UploadCheckpoint?
        if let data = try store.read(key) {
            if let saved = try? JSONDecoder().decode(UploadCheckpoint.self, from: data),
                saved.digest == digest.sha256 && saved.size == item.size &&
                (0..<(6 * 86400)).contains(Date().timeIntervalSince(saved.created)) && validSession(saved.session) {
                checkpoint = saved
            } else { try store.remove(key) }
        }
        var offset: Int64 = 0
        var mustQuery = checkpoint != nil
        var failures = 0
        var restarts = 0
        while true {
            try Task.checkCancellation()
            try item.verify(handle)
            do {
                if checkpoint == nil {
                    var req = URLRequest(url: initiationURL(item.objectName))
                    req.httpMethod = "POST"
                    req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
                    req.setValue(String(item.size), forHTTPHeaderField: "X-Upload-Content-Length")
                    req.setValue(item.contentType, forHTTPHeaderField: "X-Upload-Content-Type")
                    // GCS validates this checksum before creating the final object.
                    req.httpBody = try JSONSerialization.data(withJSONObject: ["name": item.objectName,
                        "contentType": item.contentType, "md5Hash": digest.md5])
                    let (_, response) = try await authorized(req)
                    if response.statusCode == 412 { try store.remove(key); return .existing }
                    guard (200...299).contains(response.statusCode) else { throw ServiceFailure(status: response.statusCode) }
                    guard let location = response.value(forHTTPHeaderField: "Location"),
                          let url = URL(string: location), validSession(url) else {
                        throw ArchiveError("Google returned an unexpected upload address; stopped for safety.")
                    }
                    let saved = UploadCheckpoint(session: url, digest: digest.sha256, size: item.size, created: Date())
                    try store.write(key, data: JSONEncoder().encode(saved))
                    checkpoint = saved; offset = 0; mustQuery = false
                }
                let session = checkpoint!.session
                var req = URLRequest(url: session)
                req.httpMethod = "PUT"
                if mustQuery {
                    req.setValue("bytes */\(item.size)", forHTTPHeaderField: "Content-Range")
                    req.httpBody = Data()
                } else {
                    guard offset < item.size else { throw ArchiveError("Upload has all bytes but no completion response. Retry to verify it.") }
                    try handle.seek(toOffset: UInt64(offset))
                    let count = Int(min(Int64(Self.chunkSize), item.size - offset))
                    let data = try handle.read(upToCount: count) ?? Data()
                    guard data.count == count else { throw ArchiveError("The source file became shorter during upload.") }
                    try item.verify(handle)
                    req.httpBody = data
                    req.setValue(item.contentType, forHTTPHeaderField: "Content-Type")
                    req.setValue("bytes \(offset)-\(offset + Int64(count) - 1)/\(item.size)", forHTTPHeaderField: "Content-Range")
                }
                req.setValue(String(req.httpBody!.count), forHTTPHeaderField: "Content-Length")
                let (data, response) = try await http.send(req)
                switch response.statusCode {
                case 200, 201:
                    try completed(data, item: item, digest: digest)
                    try store.remove(key)
                    await progress(UploadProgress(bytes: item.size, message: "Uploaded and checksum verified"))
                    return .uploaded
                case 308:
                    let next = try Self.acknowledgedOffset(response, total: item.size)
                    if !mustQuery && next <= offset { throw ServiceFailure(status: 503) }
                    if !mustQuery && next > offset + Int64(req.httpBody?.count ?? 0) {
                        throw ArchiveError("Google acknowledged bytes that were not sent. Retry to recheck the upload session.")
                    }
                    guard next >= offset else { throw ArchiveError("Google’s upload offset moved backwards. Retry to recheck the session.") }
                    offset = next; mustQuery = false
                    await progress(UploadProgress(bytes: offset, message: "Uploading…"))
                case 412:
                    try store.remove(key); return .existing
                case 404, 410:
                    restarts += 1
                    guard restarts <= 2 else { throw ArchiveError("Google repeatedly expired the upload session. Retry later.") }
                    try store.remove(key); checkpoint = nil; offset = 0; mustQuery = false
                    if try await exists(item) { return .existing }
                default: throw ServiceFailure(status: response.statusCode)
                }
                // A successful status query alone does not reset retries: a repeatedly failing chunk must stop.
                if req.httpBody?.isEmpty == false { failures = 0 }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard isRetryable(error), failures < 5 else { throw error }
                await progress(UploadProgress(bytes: offset, message: "Connection interrupted — retry \(failures + 1) of 5…"))
                try await delay(failures); failures += 1
                mustQuery = checkpoint != nil
            }
        }
    }
}
