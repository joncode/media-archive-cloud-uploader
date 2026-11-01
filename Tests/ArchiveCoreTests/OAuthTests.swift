import XCTest
import CryptoKit
@testable import MediaArchiveCloudUploader

final class OAuthTests: XCTestCase {
    @MainActor func testPKCEAndFormEncoding() async throws {
        // RFC 7636 known S256 vector.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(GoogleLogin.base64url(Data(SHA256.hash(data: Data(verifier.utf8)))),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let random = try GoogleLogin.random()
        XCTAssertEqual(random.count, 43)
        XCTAssertFalse(random.contains("="))
        XCTAssertEqual(String(decoding: GoogleLogin.form(["code": "a+b& c"]), as: UTF8.self), "code=a%2Bb%26%20c")
    }
    @MainActor func testLoopbackRejectsInvalidStateAndAcceptsValidCallback() async throws {
        let receiver = try LoopbackLogin(state: "random-test-state")
        defer { receiver.stop() }
        let redirect = try await receiver.start()
        XCTAssertTrue(redirect.hasPrefix("http://127.0.0.1:"))
        let (_, bad) = try await URLSession.shared.data(from: URL(string: redirect + "?state=wrong&code=bad")!)
        XCTAssertEqual((bad as? HTTPURLResponse)?.statusCode, 400)
        let (_, duplicate) = try await URLSession.shared.data(from: URL(string: redirect + "?state=random-test-state&state=wrong&code=bad")!)
        XCTAssertEqual((duplicate as? HTTPURLResponse)?.statusCode, 400)
        let waiter = Task { try await receiver.code() }
        let (_, good) = try await URLSession.shared.data(from: URL(string: redirect + "?state=random-test-state&code=test-code")!)
        XCTAssertEqual((good as? HTTPURLResponse)?.statusCode, 200)
        let code = try await waiter.value
        XCTAssertEqual(code, "test-code")
    }
    @MainActor func testLoopbackCancellationUnblocksWaiter() async throws {
        let receiver = try LoopbackLogin(state: "state")
        _ = try await receiver.start()
        let waiter = Task { try await receiver.code() }
        receiver.stop()
        do { _ = try await waiter.value; XCTFail("Must cancel") }
        catch is CancellationError {}
    }
    @MainActor func testLoopbackDeniedConsent() async throws {
        let receiver = try LoopbackLogin(state: "state")
        defer { receiver.stop() }
        let redirect = try await receiver.start()
        _ = try await URLSession.shared.data(from: URL(string: redirect + "?state=state&error=access_denied")!)
        do { _ = try await receiver.code(); XCTFail("Must reject denied consent") }
        catch { XCTAssertTrue(error.localizedDescription.contains("declined")) }
    }
}
