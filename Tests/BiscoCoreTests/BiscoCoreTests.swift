import XCTest
import Foundation
@testable import BiscoCore

final class MemoryStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return entries[key] }
    func write(_ key: String, data: Data) throws { lock.lock(); defer { lock.unlock() }; entries[key] = data }
    func remove(_ key: String) throws { lock.lock(); defer { lock.unlock() }; entries.removeValue(forKey: key) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
}

actor ScriptedHTTP: HTTPTransport {
    typealias Step = @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
    var steps: [Step]
    var requests: [URLRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !steps.isEmpty else { throw ArchiveError("Unexpected HTTP request") }
        return try steps.removeFirst()(request)
    }
    var remaining: Int { steps.count }
}

final class BiscoCoreTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func wav(_ name: String = "show/track.WAV", payload: Int = 1000) throws -> AudioItem {
        var data = Data()
        func ascii(_ s: String) { data.append(Data(s.utf8)) }
        func u32(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func u16(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(payload + 36)); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(44100); u32(88200); u16(2); u16(16); ascii("data"); u32(UInt32(payload))
        data.append(Data(repeating: 0, count: payload))
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return AudioItem(url: url, objectName: name, stamp: try FileStamp.read(url))
    }
    func response(_ code: Int, headers: [String: String] = [:], data: Data = Data()) -> ScriptedHTTP.Step {
        { req in (data, HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!) }
    }
    var session: String { "https://storage.googleapis.com/upload/storage/v1/b/test-bucket/o?uploadType=resumable&upload_id=test-only" }
    func completed(_ item: AudioItem) throws -> Data {
        let h = try item.openUnchanged(); defer { try? h.close() }
        return try JSONSerialization.data(withJSONObject: ["name": item.objectName, "size": String(item.size),
            "md5Hash": try Digests.read(item, handle: h).md5])
    }
    func client(_ http: HTTPTransport, _ store: MemoryStore = MemoryStore()) -> StorageClient {
        try! StorageClient(bucket: "test-bucket", http: http, store: store, token: { _ in "test-token" }, delay: { _ in try Task.checkCancellation() })
    }
    func testScannerFiltersAndPreservesPaths() throws {
        _ = try wav("concert/track.WAV")
        _ = try wav("concert/._track.wav")
        _ = try wav(".hidden/track.wav")
        let bogus = root.appendingPathComponent("fake.flac")
        try Data("not audio".utf8).write(to: bogus)
        try Data("project".utf8).write(to: root.appendingPathComponent("concert/project.RPP"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.wav"), withDestinationURL: root.appendingPathComponent("concert/track.WAV"))
        let result = try AudioScanner.scan(folder: root, includeFolder: false)
        XCTAssertEqual(result.items.map(\.objectName), ["concert/track.WAV"])
        XCTAssertTrue(result.excluded.contains { $0.hasPrefix("fake.flac") })
        XCTAssertTrue(result.excluded.contains { $0.hasPrefix("concert/project.RPP") })
        XCTAssertTrue(result.excluded.contains { $0.hasPrefix("linked.wav") })
        XCTAssertTrue(result.excluded.contains { $0.hasPrefix(".hidden") })
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(try AudioScanner.scan(folder: root, includeFolder: true).items.first?.objectName, root.lastPathComponent + "/concert/track.WAV")
    }
    func testFalseExtensionRejected() throws {
        _ = try wav("renamed.flac")
        XCTAssertTrue(try AudioScanner.scan(folder: root, includeFolder: false).items.isEmpty)
    }
    func testActualFLACMP3AndLargeWAVContainers() throws {
        for name in ["silence.flac", "silence.mp3", "rf64.wav", "bw64.wav"] {
            let source = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + name)
            try FileManager.default.copyItem(at: source, to: root.appendingPathComponent(name))
        }
        let result = try AudioScanner.scan(folder: root, includeFolder: false)
        XCTAssertEqual(result.items.map(\.objectName), ["bw64.wav", "rf64.wav", "silence.flac", "silence.mp3"])
        XCTAssertTrue(result.excluded.isEmpty)
    }
    func testChangedAndSymlinkSourcesRejected() throws {
        let item = try wav()
        try Data("changed".utf8).write(to: item.url)
        XCTAssertThrowsError(try item.openUnchanged())
        let fresh = try wav("fresh.wav")
        try FileManager.default.removeItem(at: fresh.url)
        try FileManager.default.createSymbolicLink(at: fresh.url, withDestinationURL: item.url)
        XCTAssertThrowsError(try fresh.openUnchanged())
    }
    func testEscapingAndPrecondition() async {
        let storage = client(ScriptedHTTP([]))
        let name = "show/a + # ? % é.wav"
        let url = await storage.objectURL(name)
        XCTAssertTrue(url.absoluteString.contains("show%2F"))
        XCTAssertEqual(url.pathComponents.last, name)
        let components = URLComponents(url: await storage.initiationURL(name), resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.queryItems?.first { $0.name == "name" }?.value, name)
        XCTAssertEqual(components.queryItems?.first { $0.name == "ifGenerationMatch" }?.value, "0")
        let insecure = await storage.validSession(URL(string: "http://storage.googleapis.com/?upload_id=x")!)
        XCTAssertFalse(insecure)
        let untrusted = await storage.validSession(URL(string: "https://evil.example/?upload_id=x")!)
        XCTAssertFalse(untrusted)
        let valid = await storage.validSession(URL(string: session)!)
        XCTAssertTrue(valid)
    }
    func testExistingAndDryRunOnlyRead() async throws {
        let item = try wav()
        let http = ScriptedHTTP([response(200), response(200)])
        let c = client(http)
        let present = try await c.exists(item)
        XCTAssertTrue(present)
        let result = try await c.upload(item) { _ in XCTFail("Existing files should not upload") }
        XCTAssertEqual(result, .existing)
        let requests = await http.requests
        XCTAssertTrue(requests.allSatisfy { ($0.httpMethod ?? "GET") == "GET" })
    }
    func testPermissionDeniedNeverMeansAbsent() async throws {
        let item = try wav()
        let http = ScriptedHTTP([response(403)])
        do { _ = try await client(http).upload(item) { _ in }; XCTFail("Must refuse") }
        catch let e as ServiceFailure { XCTAssertEqual(e.status, 403) }
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "GET")
    }
    func testUploadUsesChecksumAndAtomicPrecondition() async throws {
        let item = try wav()
        let store = MemoryStore()
        let http = ScriptedHTTP([response(404), response(200, headers: ["Location": session]), response(200, data: try completed(item))])
        let result = try await client(http, store).upload(item) { _ in }
        XCTAssertEqual(result, .uploaded); XCTAssertEqual(store.count, 0)
        let requests = await http.requests
        XCTAssertEqual(requests.map { $0.httpMethod! }, ["GET", "POST", "PUT"])
        XCTAssertTrue(requests[1].url!.absoluteString.contains("ifGenerationMatch=0"))
        let metadata = try JSONSerialization.jsonObject(with: requests[1].httpBody!) as! [String: String]
        XCTAssertNotNil(metadata["md5Hash"])
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Content-Range"), "bytes 0-\(item.size - 1)/\(item.size)")
        XCTAssertNil(requests[2].value(forHTTPHeaderField: "Authorization"))
    }
    func testRaceSkipsOn412() async throws {
        let item = try wav()
        let http = ScriptedHTTP([response(404), response(412)])
        let result = try await client(http).upload(item) { _ in }
        XCTAssertEqual(result, .existing)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
    }
    func testInterruptedChunkQueriesThenResumes() async throws {
        let item = try wav(payload: 9 * 1024 * 1024)
        let http = ScriptedHTTP([
            response(404), response(200, headers: ["Location": session]),
            { _ in throw NetworkFailure(code: -1005) },
            response(308, headers: ["Range": "bytes=0-262143"]),
            response(308, headers: ["Range": "bytes=0-8650751"]),
            response(200, data: try completed(item))
        ])
        let result = try await client(http).upload(item) { _ in }
        XCTAssertEqual(result, .uploaded)
        let requests = await http.requests
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Content-Range"), "bytes */\(item.size)")
        XCTAssertEqual(requests[4].value(forHTTPHeaderField: "Content-Range"), "bytes 262144-8650751/\(item.size)")
        XCTAssertEqual(requests[4].httpBody?.count, StorageClient.chunkSize)
    }
    func testResumeAcrossClientRestartAndCancellation() async throws {
        let item = try wav()
        let store = MemoryStore()
        let first = ScriptedHTTP([response(404), response(200, headers: ["Location": session]), { _ in throw CancellationError() }])
        do { _ = try await client(first, store).upload(item) { _ in }; XCTFail("Must cancel") }
        catch is CancellationError {}
        XCTAssertEqual(store.count, 1)
        let second = ScriptedHTTP([response(404), response(308), response(200, data: try completed(item))])
        let result = try await client(second, store).upload(item) { _ in }
        XCTAssertEqual(result, .uploaded)
        let requests = await second.requests
        XCTAssertEqual(requests.map { $0.httpMethod! }, ["GET", "PUT", "PUT"])
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Content-Range"), "bytes */\(item.size)")
        XCTAssertEqual(store.count, 0)
    }
    func testExpiredSessionRestartsSafely() async throws {
        let item = try wav()
        let http = ScriptedHTTP([response(404), response(200, headers: ["Location": session]), response(410),
            response(404), response(200, headers: ["Location": session]), response(200, data: try completed(item))])
        let result = try await client(http).upload(item) { _ in }
        XCTAssertEqual(result, .uploaded)
        let posts = await http.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertTrue(posts.allSatisfy { $0.url!.absoluteString.contains("ifGenerationMatch=0") })
    }
    func testCompletionChecksumMismatchIsError() async throws {
        let item = try wav()
        let http = ScriptedHTTP([response(404), response(200, headers: ["Location": session]), response(200, data: Data("{}".utf8))])
        do { _ = try await client(http).upload(item) { _ in }; XCTFail("Must verify") }
        catch { XCTAssertTrue(error.localizedDescription.contains("could not be verified")) }
    }
    func testRetryBudgetDoesNotResetAfterStatusQuery() async throws {
        let item = try wav()
        var steps = [response(404), response(200, headers: ["Location": session])]
        for _ in 0..<5 { steps.append(response(503)); steps.append(response(308)) }
        steps.append(response(503))
        let http = ScriptedHTTP(steps)
        do { _ = try await client(http).upload(item) { _ in }; XCTFail("Must stop retrying") }
        catch let e as ServiceFailure { XCTAssertEqual(e.status, 503) }
        let remaining = await http.remaining
        XCTAssertEqual(remaining, 0)
    }
    func testMalformedRangeRejected() throws {
        let response = HTTPURLResponse(url: URL(string: session)!, statusCode: 308, httpVersion: nil,
                                       headerFields: ["Range": "bytes=0-999999"])!
        XCTAssertThrowsError(try StorageClient.acknowledgedOffset(response, total: 100))
    }
}
