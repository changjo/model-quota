// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ModelQuota",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ModelQuota", targets: ["ModelQuota"])],
    targets: [
        .target(name: "ModelQuotaCore"),
        .executableTarget(name: "ModelQuota", dependencies: ["ModelQuotaCore"]),
        .testTarget(name: "ModelQuotaCoreTests", dependencies: ["ModelQuotaCore"],
                    resources: [.copy("Fixtures")])
    ]
)
