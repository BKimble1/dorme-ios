// swift-tools-version:5.9
// DORMEKit: platform-neutral models, clients and logic for the DORM-E iPhone app.
// NOT COMPILED YET: written on Windows without Xcode. Run `swift test` on a Mac to compile and test.
import PackageDescription

let package = Package(
    name: "DORMEKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "DORMEKit", targets: ["DORMEKit"])],
    targets: [
        .target(name: "DORMEKit"),
        .testTarget(name: "DORMEKitTests", dependencies: ["DORMEKit"]),
    ]
)
