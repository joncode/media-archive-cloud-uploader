import XCTest
@testable import ArchiveCore

final class ConfigurationTests: XCTestCase {
    func testMissingBucketHasNoFallback() {
        XCTAssertThrowsError(try ArchiveConfiguration(environment: [:]))
        XCTAssertThrowsError(try StorageClient(bucket: "", store: MemoryStore(), token: { _ in "test" }))
    }
    func testProcessEnvironmentOverridesFileAndSourceIsOptional() throws {
        let value = try ArchiveConfiguration(environment: ["BISCO_GCS_BUCKET": "process-bucket", "BISCO_SOURCE_FOLDER": ""],
            fileValues: ["BISCO_GCS_BUCKET": "file-bucket", "BISCO_SOURCE_FOLDER": "/example/audio"])
        XCTAssertEqual(value.bucket, "process-bucket")
        XCTAssertNil(value.sourceFolder)
    }
    func testQuotedPathsAndLiteralValues() throws {
        let values = try ArchiveConfiguration.parse("# local config\nBISCO_GCS_BUCKET=test-bucket\nBISCO_SOURCE_FOLDER=\"/example/audio with spaces/$literal\"\n")
        let value = try ArchiveConfiguration(environment: [:], fileValues: values)
        XCTAssertEqual(value.sourceFolder?.path, "/example/audio with spaces/$literal")
    }
    func testInvalidDestinationAndRelativeSourceAreRejected() {
        for bucket in ["gs://test-bucket/", "test-bucket/path", "a?query=yes", "a#fragment", "UPPERCASE", "ab", "a..b", "a%2fb"] {
            XCTAssertThrowsError(try ArchiveConfiguration(environment: ["BISCO_GCS_BUCKET": bucket]))
        }
        XCTAssertThrowsError(try ArchiveConfiguration(environment: ["BISCO_GCS_BUCKET": "test-bucket", "BISCO_SOURCE_FOLDER": "relative/path"]))
    }
    func testMalformedConfigIsRejectedWithoutShellExecution() {
        for text in ["BISCO_GCS_BUCKET=a\nBISCO_GCS_BUCKET=b", "UNKNOWN=value", "BISCO_GCS_BUCKET='unterminated", "echo hello"] {
            XCTAssertThrowsError(try ArchiveConfiguration.parse(text))
        }
        let values = try? ArchiveConfiguration.parse("BISCO_GCS_BUCKET=$(echo test-bucket)")
        XCTAssertThrowsError(try ArchiveConfiguration(environment: [:], fileValues: values ?? [:]))
    }
    func testExplicitEnvironmentFileLoading() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try "BISCO_GCS_BUCKET=file-bucket\nBISCO_SOURCE_FOLDER=\n".write(to: file, atomically: true, encoding: .utf8)
        let config = try ArchiveConfiguration.load(environment: ["BISCO_ENV_FILE": file.path])
        XCTAssertEqual(config.bucket, "file-bucket")
        XCTAssertThrowsError(try ArchiveConfiguration.load(environment: ["BISCO_ENV_FILE": file.path + "-missing"]))
    }
    func testResumableSessionCannotCrossConfiguredBuckets() async throws {
        let storage = try StorageClient(bucket: "second-bucket", store: MemoryStore(), token: { _ in "test" })
        let old = URL(string: "https://storage.googleapis.com/upload/storage/v1/b/test-bucket/o?upload_id=test")!
        let valid = await storage.validSession(old)
        XCTAssertFalse(valid)
        let url = await storage.initiationURL("show/track.wav")
        XCTAssertTrue(url.path.contains("/b/second-bucket/o"))
        XCTAssertTrue(url.absoluteString.contains("ifGenerationMatch=0"))
    }
}
