import XCTest
import CryptoKit
import Network
@testable import ArchiveCore
@testable import MediaArchiveCloudUploader

private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Double = 0
    func read() -> Double { lock.lock(); defer { lock.unlock() }; return now }
    func set(_ value: Double) { lock.lock(); defer { lock.unlock() }; now = value }
}

private actor WorkflowStorage: ArchiveStorage {
    var calls: [String] = []
    var uploaded = Set<String>()
    var active = 0
    var peak = 0
    var failedOnce = false
    let existing: Set<String>
    let deniedCheck: Bool
    let deniedUpload: Bool
    let failOnce: Bool
    var blocked: Bool
    let blockChecks: Bool
    init(existing: Set<String> = [], deniedCheck: Bool = false, deniedUpload: Bool = false,
         failOnce: Bool = false, blocked: Bool = false, blockChecks: Bool = false) {
        self.existing = existing; self.deniedCheck = deniedCheck; self.deniedUpload = deniedUpload
        self.failOnce = failOnce; self.blocked = blocked; self.blockChecks = blockChecks
    }
    func release() { blocked = false }
    func exists(_ item: AudioItem) async throws -> Bool {
        calls.append("check:" + item.objectName)
        if blockChecks { while blocked { try await Task.sleep(nanoseconds: 5_000_000) } }
        if deniedCheck { throw ServiceFailure(status: 403) }
        return existing.contains(item.objectName) || uploaded.contains(item.objectName)
    }
    func upload(_ item: AudioItem, statistics: TransferStatistics?,
                progress: @escaping @Sendable (UploadProgress) async -> Void) async throws -> UploadResult {
        calls.append("upload:" + item.objectName)
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        if existing.contains(item.objectName) || uploaded.contains(item.objectName) { return .existing }
        await progress(UploadProgress(bytes: 0, message: "Checking file integrity…", phase: .checking))
        if deniedUpload && item.objectName == "a.wav" { throw ServiceFailure(status: 403) }
        while blocked { try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 20_000_000)
        try Task.checkCancellation()
        if failOnce && item.objectName == "a.wav" && !failedOnce {
            failedOnce = true; throw ServiceFailure(status: 503)
        }
        if let statistics {
            let id = statistics.beginRequest(); statistics.sent(item.size, request: id); statistics.endRequest(id)
        }
        await progress(UploadProgress(bytes: item.size, message: "Uploaded", newBytes: item.size))
        uploaded.insert(item.objectName)
        return .uploaded
    }
}

private actor DelayedTokenHTTP: HTTPTransport {
    var requests = 0
    var blocked = true
    var waiters: [CheckedContinuation<Void, Never>] = []
    func release() { blocked = false; waiters.forEach { $0.resume() }; waiters = [] }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        // Deliberately allow a late response even if sign-out cancelled the refresh.
        if blocked { await withCheckedContinuation { waiters.append($0) } }
        return (Data(#"{"access_token":"test-access","expires_in":3600,"refresh_token":"rotated-refresh"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

extension ArchiveCoreTests {
    @MainActor private func workflow(_ storage: WorkflowStorage) throws -> UploadModel {
        let login = GoogleLogin(store: MemoryStore(), http: ScriptedHTTP([])); login.email = "test@example.invalid"
        let model = UploadModel(login: login, loadConfiguration: false,
            preferencesFile: root.appendingPathComponent("settings/settings.json"), storageOverride: storage)
        try model.applyConfiguration(ArchiveConfiguration(environment: ["BISCO_GCS_BUCKET": "test-bucket", "BISCO_SOURCE_FOLDER": root.path]))
        return model
    }
    @MainActor private func eventually(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for operation")
        throw ArchiveError("Test timeout")
    }
    @MainActor func testStartPreparesThenUploadsWithoutPreviewAtEveryConcurrency() async throws {
        for name in ["a", "b", "c", "d", "e", "f"] { _ = try wav(name + ".wav") }
        for limit in [1, 2, 4] {
            let storage = WorkflowStorage()
            let model = try workflow(storage); model.simultaneousUploads = limit
            XCTAssertFalse(model.previewReady); XCTAssertTrue(model.canStart)
            model.upload(); await model.waitForIdle()
            XCTAssertNil(model.error); XCTAssertFalse(model.busy)
            XCTAssertEqual(model.finishedCount, 6)
            let peak = await storage.peak
            XCTAssertEqual(peak, limit)
            let calls = await storage.calls
            XCTAssertEqual(calls.prefix(6).filter { $0.hasPrefix("check:") }.count, 6)
            XCTAssertEqual(calls.dropFirst(6).filter { $0.hasPrefix("upload:") }.count, 6)
        }
    }
    @MainActor func testPreviewRemainsReadOnlyAndStartReusesIt() async throws {
        _ = try wav("a.wav"); _ = try wav("b.wav")
        let storage = WorkflowStorage(existing: ["a.wav"])
        let model = try workflow(storage)
        model.preview(); await model.waitForIdle()
        let before = await storage.calls
        XCTAssertEqual(before, ["check:a.wav", "check:b.wav"])
        XCTAssertTrue(model.previewReady); XCTAssertNil(model.started)
        model.upload(); await model.waitForIdle()
        let after = await storage.calls
        XCTAssertEqual(after.filter { $0.hasPrefix("check:") }.count, 2)
        XCTAssertEqual(model.finishedCount, 2); XCTAssertEqual(model.skippedCount, 1)
        XCTAssertEqual(model.transferred, model.rows.first { $0.item.objectName == "b.wav" }!.item.size)
    }
    @MainActor func testStartStopsOnPreparationPermissionErrorWithoutUploads() async throws {
        _ = try wav("a.wav"); _ = try wav("b.wav")
        let storage = WorkflowStorage(deniedCheck: true)
        let model = try workflow(storage)
        model.upload(); await model.waitForIdle()
        XCTAssertNotNil(model.error); XCTAssertNil(model.started)
        let calls = await storage.calls
        XCTAssertEqual(calls, ["check:a.wav"])
    }
    @MainActor func testCancelDuringPreparationNeverStartsUploads() async throws {
        _ = try wav("a.wav")
        let storage = WorkflowStorage(blocked: true, blockChecks: true)
        let model = try workflow(storage)
        model.upload()
        try await eventually { await storage.calls.count == 1 }
        model.cancel(); await model.waitForIdle()
        let calls = await storage.calls
        XCTAssertEqual(calls, ["check:a.wav"])
        XCTAssertFalse(model.previewReady); XCTAssertFalse(model.busy)
    }
    @MainActor func testCancelDrainsActiveWorkersAndRetryCompletes() async throws {
        for name in ["a", "b", "c", "d"] { _ = try wav(name + ".wav") }
        let storage = WorkflowStorage(blocked: true)
        let model = try workflow(storage); model.simultaneousUploads = 2
        model.upload()
        try await eventually { await storage.active == 2 }
        model.cancel(); await model.waitForIdle()
        let active = await storage.active, calls = await storage.calls
        XCTAssertEqual(active, 0)
        XCTAssertEqual(calls.filter { $0.hasPrefix("upload:") }.count, 2)
        XCTAssertFalse(model.busy); XCTAssertEqual(model.finishedCount, 0)
        await storage.release(); model.upload(); await model.waitForIdle()
        XCTAssertEqual(model.finishedCount, 4); XCTAssertNil(model.error)
    }
    @MainActor func testFatalAuthorizationStopsQueueAndCancelsOtherWorkers() async throws {
        for name in ["a", "b", "c", "d"] { _ = try wav(name + ".wav") }
        let storage = WorkflowStorage(deniedUpload: true, blocked: true)
        let model = try workflow(storage); model.simultaneousUploads = 2
        model.upload(); await model.waitForIdle()
        let active = await storage.active, calls = await storage.calls
        XCTAssertEqual(active, 0)
        XCTAssertLessThanOrEqual(calls.filter { $0.hasPrefix("upload:") }.count, 2)
        XCTAssertNotNil(model.error); XCTAssertFalse(model.busy)
    }
    @MainActor func testPerFileFailureDoesNotStopOthersAndRetrySkipsFinishedRows() async throws {
        _ = try wav("a.wav"); _ = try wav("b.wav"); _ = try wav("c.wav")
        let storage = WorkflowStorage(failOnce: true)
        let model = try workflow(storage)
        model.upload(); await model.waitForIdle()
        XCTAssertEqual(model.finishedCount, 2); XCTAssertEqual(model.failedCount, 1)
        model.upload(); await model.waitForIdle()
        XCTAssertEqual(model.finishedCount, 3); XCTAssertEqual(model.failedCount, 0)
        let calls = await storage.calls
        XCTAssertEqual(calls.filter { $0 == "upload:b.wav" }.count, 1)
        XCTAssertEqual(calls.filter { $0 == "upload:a.wav" }.count, 2)
    }
    @MainActor func testEmptySelectionCanStartAgainAfterFilesArrive() async throws {
        let model = try workflow(WorkflowStorage())
        model.upload(); await model.waitForIdle()
        XCTAssertNil(model.error); XCTAssertEqual(model.finishedCount, 0); XCTAssertTrue(model.canStart)
        _ = try wav("new.wav")
        model.upload(); await model.waitForIdle()
        XCTAssertEqual(model.finishedCount, 1)
    }
    @MainActor func testAutomaticStartBlocksScanIssuesAndKeepsReport() async throws {
        _ = try wav("a.wav"); _ = try wav("invalid\nname.wav")
        let storage = WorkflowStorage(), model = try workflow(storage)
        model.upload(); await model.waitForIdle()
        XCTAssertNotNil(model.error); XCTAssertFalse(model.issues.isEmpty); XCTAssertTrue(model.canExportReport)
        let calls = await storage.calls
        XCTAssertFalse(calls.contains { $0.hasPrefix("upload:") })
    }
    @MainActor func testCancellingSharedRefreshPreservesLoginForRetry() async throws {
        let http = DelayedTokenHTTP(), store = try loginStore()
        let login = GoogleLogin(store: store, http: http)
        let request = Task { try await login.token(forceRefresh: false) }
        try await eventually { await http.requests == 1 }
        login.cancel(); await http.release()
        do { _ = try await request.value; XCTFail("Cancelled token must be discarded") } catch is CancellationError {}
        XCTAssertNotNil(try store.read("oauth-login")); XCTAssertFalse(login.email.isEmpty)
        let token = try await login.token(forceRefresh: false)
        XCTAssertEqual(token, "test-access")
        let count = await http.requests
        XCTAssertEqual(count, 2)
    }
    func testRateCountsParallelTrafficAndRetriesButIgnoresLateCallbacks() throws {
        let clock = ManualClock(), meter = TransferStatistics(clock: { 0 })
        XCTAssertNil(meter.snapshot(remainingBytes: 100).bytesPerSecond)
        let stats = TransferStatistics(clock: { clock.read() })
        let a = stats.beginRequest(), b = stats.beginRequest()
        stats.sent(1000, request: a); stats.sent(500, request: a); stats.sent(1000, request: a)
        stats.sent(2000, request: b); stats.confirm(3000)
        clock.set(2)
        let snapshot = stats.snapshot(remainingBytes: 6000)
        XCTAssertEqual(snapshot.sentBytes, 3000)
        XCTAssertEqual(snapshot.bytesPerSecond!, 1500, accuracy: 0.01)
        XCTAssertEqual(snapshot.remainingSeconds!, 4, accuracy: 0.01)
        stats.endRequest(a); stats.sent(9000, request: a)
        let retry = stats.beginRequest(); stats.sent(1000, request: retry)
        clock.set(3)
        XCTAssertEqual(stats.snapshot(remainingBytes: 6000).sentBytes, 4000)
        for time in 4...16 { clock.set(Double(time)); _ = stats.snapshot(remainingBytes: 6000) }
        XCTAssertEqual(stats.snapshot(remainingBytes: 6000).bytesPerSecond, 0)
        XCTAssertNil(stats.snapshot(remainingBytes: 6000).remainingSeconds)
    }
    func testOldCheckpointResumesWithoutInflatingSpeedOrETA() async throws {
        let item = try wav(payload: 100_000), store = MemoryStore(), clock = ManualClock()
        let handle = try item.openUnchanged(); let digest = try Digests.read(item, handle: handle); try handle.close()
        let oldOffset: Int64 = 65536
        let key = "upload-" + SHA256.hash(data: Data(("test-bucket\n" + item.objectName + "\n" + item.url.path).utf8)).map { String(format: "%02x", $0) }.joined()
        let checkpoint = UploadCheckpoint(session: URL(string: session)!, digest: digest.sha256, size: item.size, created: Date())
        try store.write(key, data: JSONEncoder().encode(checkpoint))
        let http = ScriptedHTTP([response(404), response(308, headers: ["Range": "bytes=0-65535"]), response(200, data: try completed(item))])
        let stats = TransferStatistics(clock: { clock.read() })
        let result = try await client(http, store).upload(item, statistics: stats) { update in stats.confirm(update.newBytes) }
        clock.set(10)
        let snapshot = stats.snapshot(remainingBytes: item.size - oldOffset)
        XCTAssertEqual(result, .uploaded)
        XCTAssertEqual(snapshot.sentBytes, item.size - oldOffset)
        XCTAssertEqual(snapshot.remainingSeconds!, 10, accuracy: 0.001)
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 0)
        XCTAssertEqual(requests.last!.value(forHTTPHeaderField: "Content-Range"), "bytes \(oldOffset)-\(item.size - 1)/\(item.size)")
    }
    func testLegacySettingsDefaultConcurrencyAndValidateNewChoices() throws {
        let file = root.appendingPathComponent("settings.json")
        try Data(#"{"bucket":"test-bucket","includeFolder":false}"#.utf8).write(to: file)
        let old = try XCTUnwrap(ArchivePreferences.load(from: file))
        XCTAssertNil(old.simultaneousUploads)
        var new = old; new.simultaneousUploads = 4; try new.save(to: file)
        XCTAssertEqual(try ArchivePreferences.load(from: file)?.simultaneousUploads, 4)
        new.simultaneousUploads = 3; XCTAssertThrowsError(try new.save(to: file))
    }
    @MainActor func testConcurrentTransfersShareOneTokenRefresh() async throws {
        let http = DelayedTokenHTTP(), store = try loginStore()
        let login = GoogleLogin(store: store, http: http)
        let first = Task { try await login.token(forceRefresh: false) }
        try await eventually { await http.requests == 1 }
        let second = Task { try await login.token(forceRefresh: true) }
        await Task.yield(); await http.release()
        let tokens = try await (first.value, second.value)
        XCTAssertEqual(tokens.0, "test-access"); XCTAssertEqual(tokens.1, tokens.0)
        let count = await http.requests
        XCTAssertEqual(count, 1)
    }
    @MainActor func testSignOutCannotBeUndoneByLateTokenRefresh() async throws {
        let http = DelayedTokenHTTP(), store = try loginStore()
        let login = GoogleLogin(store: store, http: http)
        let request = Task { try await login.token(forceRefresh: false) }
        try await eventually { await http.requests == 1 }
        try login.signOut(); await http.release()
        do { _ = try await request.value; XCTFail("Late login must be discarded") } catch is CancellationError {}
        XCTAssertNil(try store.read("oauth-login")); XCTAssertTrue(login.email.isEmpty)
    }
}

// A local HTTP endpoint exercises Foundation's real upload delegate without Google
// credentials. Its 308 includes Location to verify that resumable replies aren't followed.
@MainActor private final class UploadTestServer {
    private let listener: NWListener
    private var ready: CheckedContinuation<URL, Error>?
    private var connections: [NWConnection] = []
    private(set) var requests = 0
    private(set) var receivedBytes = 0
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    if case .ready = state, let port = self.listener.port {
                        self.ready?.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/upload")!); self.ready = nil
                    } else if case .failed(let error) = state { self.ready?.resume(throwing: error); self.ready = nil }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self else { connection.cancel(); return }
                    self.connections.append(connection); self.requests += 1
                    connection.start(queue: .main)
                    self.read(connection, accumulated: Data())
                }
            }
            listener.start(queue: .main)
        }
    }
    private func read(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var accumulated = accumulated; accumulated.append(data ?? Data())
                if let end = accumulated.range(of: Data("\r\n\r\n".utf8)),
                   let header = String(data: accumulated[..<end.lowerBound], encoding: .utf8),
                   let line = header.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                   let length = Int(line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)),
                   accumulated.count - end.upperBound >= length {
                    self.receivedBytes += length
                    let reply = "HTTP/1.1 308 Resume Incomplete\r\nLocation: http://127.0.0.1:\(self.listener.port!.rawValue)/must-not-follow\r\nRange: bytes=0-\(length - 1)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                } else if done || error != nil || accumulated.count > 4 * 1024 * 1024 { connection.cancel() }
                else { self.read(connection, accumulated: accumulated) }
            }
        }
    }
    func stop() { listener.cancel(); connections.forEach { $0.cancel() }; ready?.resume(throwing: CancellationError()); ready = nil }
}

extension ArchiveCoreTests {
    @MainActor func testRealUploadProgressAnd308RedirectRefusal() async throws {
        let server = try UploadTestServer(), stats = TransferStatistics()
        let url = try await server.start(); defer { server.stop() }
        var request = URLRequest(url: url); request.httpMethod = "PUT"; request.timeoutInterval = 5
        let size = 2 * 1024 * 1024
        request.httpBody = Data(repeating: 42, count: size)
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        let id = stats.beginRequest()
        let (_, response) = try await SecureHTTP().send(request, uploadProgress: { stats.sent($0, request: id) })
        stats.endRequest(id)
        XCTAssertEqual(response.statusCode, 308)
        XCTAssertEqual(server.requests, 1); XCTAssertEqual(server.receivedBytes, size)
        XCTAssertEqual(stats.snapshot(remainingBytes: 0).sentBytes, Int64(size))
    }
}

private actor ParallelCloudHTTP: HTTPTransport {
    let metadata: [String: Data]
    var offset: [String: Int64] = [:]
    var requests: [URLRequest] = []
    var completed = Set<String>()
    var active = 0
    var peak = 0
    var interrupted = false
    init(metadata: [String: Data]) { self.metadata = metadata }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        func reply(_ status: Int, headers: [String: String] = [:], body: Data = Data()) -> (Data, HTTPURLResponse) {
            (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
        if request.httpMethod == "GET" { return reply(404) }
        if request.httpMethod == "POST" {
            let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let name = json["name"] as! String
            return reply(200, headers: ["Location": "https://storage.googleapis.com/upload/storage/v1/b/test-bucket/o?upload_id=\(name)"])
        }
        let name = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "upload_id" }!.value!
        if request.httpBody?.isEmpty != false {
            return reply(308, headers: (offset[name] ?? 0) > 0 ? ["Range": "bytes=0-\(offset[name]! - 1)"] : [:])
        }
        active += 1; peak = max(peak, active); defer { active -= 1 }
        try await Task.sleep(nanoseconds: 20_000_000)
        if name == "a.wav" && !interrupted {
            interrupted = true; offset[name] = 256
            throw NetworkFailure(code: -1005)
        }
        completed.insert(name)
        return reply(200, body: metadata[name]!)
    }
}

extension ArchiveCoreTests {
    func testStorageClientOverlapsFilesAndRecoversOneWithoutAffectingOthers() async throws {
        let a = try wav("a.wav"), b = try wav("b.wav")
        let http = ParallelCloudHTTP(metadata: ["a.wav": try completed(a), "b.wav": try completed(b)])
        let storage = client(http)
        try await BoundedWork.run([a, b], limit: 2) { item in
            let result = try await storage.upload(item) { _ in }
            XCTAssertEqual(result, .uploaded)
        }
        let peak = await http.peak, finished = await http.completed, requests = await http.requests
        XCTAssertEqual(peak, 2); XCTAssertEqual(finished, ["a.wav", "b.wav"])
        XCTAssertTrue(requests.filter { $0.httpMethod == "POST" }.allSatisfy { $0.url!.absoluteString.contains("ifGenerationMatch=0") })
        XCTAssertTrue(requests.contains { $0.value(forHTTPHeaderField: "Content-Range") == "bytes 256-\(a.size - 1)/\(a.size)" })
        XCTAssertEqual(requests.filter { $0.httpMethod == "PUT" && $0.httpBody?.isEmpty == false && $0.url!.absoluteString.contains("b.wav") }.count, 1)
    }
}
