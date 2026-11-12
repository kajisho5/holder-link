// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IQOSKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "IQOSKit", targets: ["IQOSKit"]),
    ],
    targets: [
        .target(name: "IQOSKit"),
        .testTarget(name: "IQOSKitTests", dependencies: ["IQOSKit"]),
    ]
)
