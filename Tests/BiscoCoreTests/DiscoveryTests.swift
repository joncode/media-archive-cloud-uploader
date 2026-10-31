import XCTest
@testable import BiscoCore
@testable import BiscoArchiveUploader

extension BiscoCoreTests {
    func jsonStep(_ json: String, status: Int = 200) -> ScriptedHTTP.Step {
        response(status, data: Data(json.utf8))
    }
    func directory(_ http: HTTPTransport) -> CloudDirectory {
        CloudDirectory(http: http, token: { refresh in refresh ? "fresh-token" : "old-token" }, delay: { _ in try Task.checkCancellation() })
    }
    func testProjectAndBucketPaginationWithPartialPermissions() async throws {
        let http = ScriptedHTTP([
            jsonStep(#"{"projects":[{"projectId":"a-project","state":"ACTIVE"}],"nextPageToken":"projects+2"}"#),
            jsonStep(#"{"projects":[{"projectId":"b-project","state":"ACTIVE"},{"projectId":"deleted-project","state":"DELETE_REQUESTED"}]}"#),
            jsonStep(#"{"items":[{"name":"a-bucket"}],"nextPageToken":"bucket+2"}"#),
            jsonStep(#"{"items":[{"name":"z-bucket"}]}"#),
            response(403)
        ])
        let found = try await directory(http).discover()
        XCTAssertEqual(found.buckets.map(\.name), ["a-bucket", "z-bucket"])
        XCTAssertEqual(found.buckets.map(\.projectID), ["a-project", "a-project"])
        XCTAssertEqual(found.warnings.count, 1)
        XCTAssertTrue(found.warnings[0].contains("b-project"))
        let requests = await http.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        XCTAssertEqual(requests[0].url?.host, "cloudresourcemanager.googleapis.com")
        XCTAssertTrue(requests[1].url!.absoluteString.contains("projects%2B2"))
        XCTAssertEqual(requests[2].url?.host, "storage.googleapis.com")
        XCTAssertTrue(requests[2].url!.absoluteString.contains("project=a-project"))
        XCTAssertTrue(requests[3].url!.absoluteString.contains("bucket%2B2"))
    }
    func testDirectoryRefreshesUnauthorizedTokenOnlyOnce() async throws {
        let http = ScriptedHTTP([response(401), jsonStep(#"{"items":[{"name":"test-bucket"}]}"#)])
        let buckets = try await directory(http).buckets(projectID: "test-project")
        XCTAssertEqual(buckets.count, 1)
        let requests = await http.requests
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer old-token", "Bearer fresh-token"])
        let denied = ScriptedHTTP([response(401), response(401)])
        do { _ = try await directory(denied).buckets(projectID: "test-project"); XCTFail("Expected login error") }
        catch let failure as ServiceFailure { XCTAssertEqual(failure.status, 401) }
        let count = await denied.requests.count
        XCTAssertEqual(count, 2)
    }
    func testProjectDiscoveryPermissionErrorOffersFallback() async throws {
        do { _ = try await directory(ScriptedHTTP([response(403)])).discover(); XCTFail("Expected permission failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("project ID or bucket name")) }
        let buckets = try await directory(ScriptedHTTP([jsonStep("{}")])).buckets(projectID: "123456789")
        XCTAssertTrue(buckets.isEmpty)
    }
    func testDirectoryRejectsRepeatedPagesAndMalformedResponses() async throws {
        let repeated = ScriptedHTTP([
            jsonStep(#"{"nextPageToken":"same"}"#), jsonStep(#"{"nextPageToken":"same"}"#)
        ])
        do { _ = try await directory(repeated).buckets(projectID: "test-project"); XCTFail("Expected loop guard") }
        catch { XCTAssertTrue(error.localizedDescription.contains("repeated")) }
        do { _ = try await directory(ScriptedHTTP([jsonStep("not json")])).discover(); XCTFail("Expected invalid response") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unreadable")) }
    }
    func testDirectoryTransientFailureRetriesAndCancellationStops() async throws {
        let http = ScriptedHTTP([response(503), jsonStep(#"{"items":[{"name":"test-bucket"}]}"#)])
        let result = try await directory(http).buckets(projectID: "test-project")
        XCTAssertEqual(result.count, 1)
        let pending = ScriptedHTTP([response(503)])
        let cancelled = CloudDirectory(http: pending, token: { _ in "test" }, delay: { _ in throw CancellationError() })
        do { _ = try await cancelled.buckets(projectID: "test-project"); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await pending.requests.count
        XCTAssertEqual(count, 1)
    }
    func testExplicitFilesExcludeUnselectedAudioAndUnsafeEntries() throws {
        let chosen = try wav("show/chosen.wav")
        _ = try wav("show/unselected.wav")
        let hidden = try wav("show/._chosen.wav")
        let fake = root.appendingPathComponent("show/fake.flac")
        try Data("not audio".utf8).write(to: fake)
        let reaper = root.appendingPathComponent("show/session.rpp")
        try Data("REAPER".utf8).write(to: reaper)
        let link = root.appendingPathComponent("show/link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: chosen.url)
        let result = try AudioScanner.scan(files: [chosen.url, chosen.url, hidden.url, fake, reaper, link])
        XCTAssertEqual(result.items.map(\.objectName), ["chosen.wav"])
        XCTAssertEqual(result.excluded.count, 4)
        XCTAssertTrue(result.issues.isEmpty)
        let other = try wav("other/chosen.wav")
        XCTAssertThrowsError(try AudioScanner.scan(files: [chosen.url, other.url]))
    }
    func testPreferencesRoundTripPrivatePermissionsAndInvalidData() throws {
        let file = root.appendingPathComponent("private/settings.json")
        let value = ArchivePreferences(bucket: "test-bucket", projectID: "test-project", accountEmail: "test@example.invalid",
                                       sourceFolder: root.path, includeFolder: true)
        try value.save(to: file)
        XCTAssertEqual(try ArchivePreferences.load(from: file), value)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directory = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertThrowsError(try ArchivePreferences(bucket: "gs://bad/").save(to: file))
        XCTAssertEqual(try ArchivePreferences.load(from: file), value)
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try ArchivePreferences.load(from: file))
    }
    @MainActor func testBucketSelectionPersistsInvalidatesPreviewAndIsAccountBound() throws {
        let file = root.appendingPathComponent("private/settings.json")
        let login = GoogleLogin(store: MemoryStore(), http: ScriptedHTTP([]))
        login.email = "first@example.invalid"
        let model = UploadModel(login: login, loadConfiguration: false, preferencesFile: file)
        model.folder = root; model.rememberSource(); model.previewReady = true
        model.selectBucket("test-bucket")
        XCTAssertEqual(model.configuration?.bucket, "test-bucket")
        XCTAssertFalse(model.previewReady)
        let saved = try XCTUnwrap(ArchivePreferences.load(from: file))
        XCTAssertEqual(saved.accountEmail, login.email)
        XCTAssertEqual(saved.sourceFolder, root.path)
        let restored = UploadModel(login: login, preferencesFile: file)
        XCTAssertEqual(restored.configuration?.bucket, "test-bucket")
        login.email = "second@example.invalid"
        let different = UploadModel(login: login, preferencesFile: file)
        XCTAssertNil(different.configuration)
        XCTAssertEqual(different.folder?.path, root.path)
        model.clearAccountDestination()
        XCTAssertNil(model.configuration)
        XCTAssertNil(try ArchivePreferences.load(from: file)?.bucket)
    }
    @MainActor func testSignInWithoutConfigurationShowsGuidedSetup() {
        let login = GoogleLogin(store: MemoryStore(), http: ScriptedHTTP([]))
        let model = UploadModel(login: login, loadConfiguration: false)
        model.signIn()
        XCTAssertTrue(model.showGoogleSetup)
        XCTAssertFalse(model.busy)
    }
    @MainActor func testSelectionSaveFailureDoesNotChangeDestination() throws {
        let notDirectory = root.appendingPathComponent("a-file")
        try Data().write(to: notDirectory)
        let login = GoogleLogin(store: MemoryStore(), http: ScriptedHTTP([])); login.email = "test@example.invalid"
        let model = UploadModel(login: login, loadConfiguration: false, preferencesFile: notDirectory.appendingPathComponent("settings.json"))
        model.selectBucket("test-bucket")
        XCTAssertNil(model.configuration)
        XCTAssertNotNil(model.error)
    }
}
