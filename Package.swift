// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BiscoArchiveUploader",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "BiscoArchiveUploader", targets: ["BiscoArchiveUploader"])],
    targets: [
        .target(name: "BiscoCore"),
        .executableTarget(name: "BiscoArchiveUploader", dependencies: ["BiscoCore"]),
        .testTarget(name: "BiscoCoreTests", dependencies: ["BiscoCore", "BiscoArchiveUploader"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
