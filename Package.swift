// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaArchiveCloudUploader",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MediaArchiveCloudUploader", targets: ["MediaArchiveCloudUploader"])],
    targets: [
        .target(name: "ArchiveCore"),
        .executableTarget(name: "MediaArchiveCloudUploader", dependencies: ["ArchiveCore"]),
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore", "MediaArchiveCloudUploader"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
