import XCTest
import CryptoKit
import Darwin
@testable import ArchiveCore
@testable import MediaArchiveCloudUploader

private struct LockedStore: SecretStore {
    let backing: MemoryStore
    func read(_ key: String) throws -> Data? { try backing.read(key) }
    func write(_ key: String, data: Data) throws { try backing.write(key, data: data) }
    func remove(_ key: String) throws { throw ArchiveError("Keychain locked in test") }
    func clearUploads() throws { throw ArchiveError("Keychain locked in test") }
}

extension ArchiveCoreTests {
    func testPlusSignSurvivesFormStyleQueryDecoding() async throws {
        let storage = client(ScriptedHTTP([]))
        let name = "show/a+b + c#?.wav"
        let url = await storage.initiationURL(name)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedQuery!
        XCTAssertFalse(query.contains("+"))
        let nameField = query.split(separator: "&").first { $0.hasPrefix("name=") }!
        let decoded = String(nameField.dropFirst(5)).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        XCTAssertEqual(decoded, name)
    }
    func testSecureHTTPIsReleasedWithoutDelegateCycle() {
        weak var reference: SecureHTTP?
        autoreleasepool { let http = SecureHTTP(); reference = http }
        XCTAssertNil(reference)
    }
    func testMissingAndNonDirectorySourceAreRejected() throws {
        XCTAssertThrowsError(try AudioScanner.scan(folder: root.appendingPathComponent("missing"), includeFolder: false))
        let file = try wav()
        XCTAssertThrowsError(try AudioScanner.scan(folder: file.url, includeFolder: false))
    }
    func testConfigurationReaderRejectsOversizeSymlinkAndPipe() throws {
        let large = root.appendingPathComponent("oversize.env")
        try Data(repeating: 65, count: 65537).write(to: large)
        XCTAssertThrowsError(try LocalInput.read(large))
        let link = root.appendingPathComponent("linked.env")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: large)
        XCTAssertThrowsError(try LocalInput.read(link))
        let pipe = root.appendingPathComponent("pipe.env")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        XCTAssertThrowsError(try LocalInput.read(pipe))
    }
    func testImportedConfigurationIsPrivate() throws {
        let directory = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let file = directory.appendingPathComponent(".env")
        try ArchiveConfiguration.saveImported("BISCO_GCS_BUCKET=test-bucket\nBISCO_SOURCE_FOLDER=\n", to: file)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(folderAttributes[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(fileAttributes[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try ArchiveConfiguration.parse(LocalInput.text(file))["BISCO_GCS_BUCKET"], "test-bucket")
    }
    func testCorruptCheckpointStartsNewProtectedSession() async throws {
        let item = try wav()
        let store = MemoryStore()
        let key = "upload-" + SHA256.hash(data: Data(("test-bucket\n" + item.objectName + "\n" + item.url.path).utf8))
            .map { String(format: "%02x", $0) }.joined()
        try store.write(key, data: Data("corrupted".utf8))
        let http = ScriptedHTTP([response(404), response(200, headers: ["Location": session]), response(200, data: try completed(item))])
        let result = try await client(http, store).upload(item) { _ in }
        XCTAssertEqual(result, .uploaded)
        let requests = await http.requests
        XCTAssertTrue(requests[1].url!.absoluteString.contains("ifGenerationMatch=0"))
        XCTAssertEqual(store.count, 0)
    }
    func testCancellationBeforeHashDoesNotCreateUploadSession() async throws {
        let item = try wav()
        let http = ScriptedHTTP([response(404)])
        let storage = client(http)
        let task = Task {
            try await storage.upload(item) { _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        do { _ = try await task.value; XCTFail("Must cancel") }
        catch is CancellationError {}
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "GET")
    }
    func testServerCannotAcknowledgeUnsentBytes() async throws {
        let item = try wav(payload: 9 * 1024 * 1024)
        let http = ScriptedHTTP([response(404), response(200, headers: ["Location": session]),
                                response(308, headers: ["Range": "bytes=0-9000000"])])
        do { _ = try await client(http).upload(item) { _ in }; XCTFail("Must reject invalid acknowledgement") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not sent")) }
    }
    private func loginStore() throws -> MemoryStore {
        let store = MemoryStore()
        try store.write("oauth-client", data: Data(#"{"client_id":"test.apps.googleusercontent.com"}"#.utf8))
        try store.write("oauth-login", data: Data(#"{"refreshToken":"test-refresh","email":"engineer@example.test"}"#.utf8))
        return store
    }
    @MainActor func testRefreshTokenRotationAndAccessTokenCache() async throws {
        let store = try loginStore()
        let http = ScriptedHTTP([response(200, data: Data(#"{"access_token":"test-access","expires_in":3600,"refresh_token":"rotated-refresh"}"#.utf8))])
        let login = GoogleLogin(store: store, http: http)
        let first = try await login.token(forceRefresh: false)
        let second = try await login.token(forceRefresh: false)
        XCTAssertEqual(first, "test-access"); XCTAssertEqual(second, first)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        let saved = try JSONSerialization.jsonObject(with: store.read("oauth-login")!) as! [String: String]
        XCTAssertEqual(saved["refreshToken"], "rotated-refresh")
    }
    @MainActor func testSignOutClearsMemoryWhenKeychainRemovalFails() async throws {
        let http = ScriptedHTTP([response(200, data: Data(#"{"access_token":"test-access","expires_in":3600}"#.utf8))])
        let login = GoogleLogin(store: LockedStore(backing: try loginStore()), http: http)
        _ = try await login.token(forceRefresh: false)
        XCTAssertThrowsError(try login.signOut())
        XCTAssertTrue(login.email.isEmpty)
        do { _ = try await login.token(forceRefresh: false); XCTFail("Must discard cached credentials") }
        catch is AuthenticationFailure {}
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
    }
    @MainActor func testExpiredLoginStopsPreviewAfterFirstFile() async throws {
        _ = try wav("one.wav"); _ = try wav("two.wav")
        let http = ScriptedHTTP([response(400, data: Data(#"{"error":"invalid_grant"}"#.utf8))])
        let login = GoogleLogin(store: try loginStore(), http: http)
        let model = UploadModel(login: login, loadConfiguration: false)
        try model.applyConfiguration(ArchiveConfiguration(environment: ["BISCO_GCS_BUCKET": "test-bucket", "BISCO_SOURCE_FOLDER": root.path]))
        model.preview()
        let deadline = Date().addingTimeInterval(5)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.previewReady)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.failedCount, 1)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
    }
    @MainActor func testTransientTokenErrorRetriesWithoutReauthentication() async throws {
        let item = try wav()
        let authHTTP = ScriptedHTTP([response(503), response(200, data: Data(#"{"access_token":"test-access","expires_in":3600}"#.utf8))])
        let login = GoogleLogin(store: try loginStore(), http: authHTTP)
        let storageHTTP = ScriptedHTTP([response(404)])
        let storage = try StorageClient(bucket: "test-bucket", http: storageHTTP, store: MemoryStore(),
            token: { force in try await login.token(forceRefresh: force) }, delay: { _ in })
        let exists = try await storage.exists(item)
        XCTAssertFalse(exists)
        let authRequests = await authHTTP.requests
        let storageRequests = await storageHTTP.requests
        XCTAssertEqual(authRequests.count, 2); XCTAssertEqual(storageRequests.count, 1)
    }
    @MainActor func testExcludedOnlyScanCanExportReport() async throws {
        let login = GoogleLogin(store: MemoryStore(), http: ScriptedHTTP([]))
        let model = UploadModel(login: login, loadConfiguration: false)
        XCTAssertFalse(model.canExportReport)
        model.excluded = ["project.rpp — not audio"]
        XCTAssertTrue(model.canExportReport)
        model.excluded = []; model.issues = ["Unreadable folder"]
        XCTAssertTrue(model.canExportReport)
    }
    @MainActor func testMalformedTokenResponseIsAuthenticationFailure() async throws {
        let login = GoogleLogin(store: try loginStore(), http: ScriptedHTTP([response(200, data: Data("{}".utf8))]))
        do { _ = try await login.token(forceRefresh: false); XCTFail("Must reject missing token") }
        catch is AuthenticationFailure {}
    }
}

extension OAuthTests {
    @MainActor func testTaskCancellationStopsCallbackWait() async throws {
        let receiver = try LoopbackLogin(state: "state")
        _ = try await receiver.start()
        let waiter = Task { try await receiver.code() }
        try await Task.sleep(nanoseconds: 20_000_000)
        waiter.cancel()
        do { _ = try await waiter.value; XCTFail("Must cancel") }
        catch is CancellationError {}
    }
    @MainActor func testStoppedListenerDoesNotStartAgain() async throws {
        let receiver = try LoopbackLogin(state: "state")
        receiver.stop()
        do { _ = try await receiver.start(); XCTFail("Must remain cancelled") }
        catch is CancellationError {}
    }
}
