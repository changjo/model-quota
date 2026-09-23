// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ModelQuota",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ModelQuota", targets: ["CodexUsage"])],
    targets: [
        .target(name: "CodexUsageCore"),
        .executableTarget(name: "CodexUsage", dependencies: ["CodexUsageCore"]),
        .testTarget(name: "CodexUsageCoreTests", dependencies: ["CodexUsageCore"],
                    resources: [.copy("Fixtures")])
    ]
)
