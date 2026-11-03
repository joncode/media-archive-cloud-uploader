import XCTest
@testable import ArchiveCore
@testable import MediaArchiveCloudUploader

extension ArchiveCoreTests {
    private func bundledClient(_ text: String = #"{"installed":{"client_id":"bundled.apps.googleusercontent.com","client_secret":"test-only"}}"#) throws -> URL {
        let url = root.appendingPathComponent("GoogleOAuthClient.json")
        try Data(text.utf8).write(to: url)
        return url
    }
    @MainActor func testFreshInstallUsesBundledClientWithoutWritingKeychain() throws {
        let store = MemoryStore()
        let login = GoogleLogin(store: store, http: ScriptedHTTP([]), bundledClientURL: try bundledClient())
        XCTAssertTrue(login.configured)
        XCTAssertTrue(login.email.isEmpty)
        XCTAssertNil(login.storageIssue)
        XCTAssertEqual(store.count, 0)
        try login.persistBundledClientIfNeeded()
        let client = try JSONDecoder().decode(OAuthClient.self, from: XCTUnwrap(store.read("oauth-client")))
        XCTAssertEqual(client.client_id, "bundled.apps.googleusercontent.com")
        XCTAssertNil(try store.read("oauth-login"))
        let relaunched = GoogleLogin(store: store, http: ScriptedHTTP([]), bundledClientURL: nil)
        XCTAssertTrue(relaunched.configured)
    }
    @MainActor func testSavedClientAndLoginTakePriorityOverNewBundledClient() async throws {
        let store = try loginStore()
        let http = ScriptedHTTP([response(200, data: Data(#"{"access_token":"test-access","expires_in":3600}"#.utf8))])
        let login = GoogleLogin(store: store, http: http, bundledClientURL: try bundledClient())
        XCTAssertEqual(login.email, "engineer@example.test")
        try login.persistBundledClientIfNeeded()
        _ = try await login.token(forceRefresh: false)
        let requests = await http.requests
        let body = String(decoding: requests[0].httpBody!, as: UTF8.self)
        XCTAssertTrue(body.contains("client_id=test.apps.googleusercontent.com"))
        XCTAssertFalse(body.contains("bundled.apps.googleusercontent.com"))
    }
    @MainActor func testBundledClientDoesNotInheritOrphanedLogin() async throws {
        let store = MemoryStore()
        try store.write("oauth-login", data: Data(#"{"refreshToken":"orphan","email":"old@example.test"}"#.utf8))
        let login = GoogleLogin(store: store, http: ScriptedHTTP([]), bundledClientURL: try bundledClient())
        XCTAssertTrue(login.configured); XCTAssertTrue(login.email.isEmpty)
        do { _ = try await login.token(forceRefresh: false); XCTFail("Must require sign-in") }
        catch is AuthenticationFailure {}
        try login.persistBundledClientIfNeeded()
        XCTAssertNil(try store.read("oauth-login"))
    }
    @MainActor func testMissingBundleRetainsManualSetup() {
        let login = GoogleLogin(store: MemoryStore(), http: ScriptedHTTP([]), bundledClientURL: nil)
        XCTAssertFalse(login.configured); XCTAssertNil(login.storageIssue)
    }
    @MainActor func testBundleRejectsWebServiceAccountInvalidAndOversizedInput() throws {
        for text in [#"{"web":{"client_id":"test.apps.googleusercontent.com"}}"#,
                     #"{"type":"service_account","private_key":"test"}"#,
                     #"{"installed":{"client_id":"invalid"}}"#,
                     #"{"installed":{"client_id":".apps.googleusercontent.com"}}"#,
                     String(repeating: " ", count: 65536)] {
            let login = GoogleLogin(store: MemoryStore(), http: ScriptedHTTP([]), bundledClientURL: try bundledClient(text))
            XCTAssertFalse(login.configured); XCTAssertNotNil(login.storageIssue)
        }
    }
    @MainActor func testManualImportOverridesBundledClientAndClearsOldLogin() throws {
        let store = MemoryStore()
        let login = GoogleLogin(store: store, http: ScriptedHTTP([]), bundledClientURL: try bundledClient())
        let replacement = try bundledClient(#"{"installed":{"client_id":"replacement.apps.googleusercontent.com"}}"#)
        try login.importClient(replacement)
        try login.persistBundledClientIfNeeded()
        let client = try JSONDecoder().decode(OAuthClient.self, from: XCTUnwrap(store.read("oauth-client")))
        XCTAssertEqual(client.client_id, "replacement.apps.googleusercontent.com")
        XCTAssertTrue(login.configured); XCTAssertTrue(login.email.isEmpty)
    }
}
