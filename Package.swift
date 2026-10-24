// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MetaStudyCore",
    platforms: [.iOS("17.2"), .macOS(.v13)],
    products: [.library(name: "MetaStudyCore", targets: ["MetaStudyCore"])],
    targets: [
        .target(name: "MetaStudyCore"),
        .testTarget(name: "MetaStudyCoreTests", dependencies: ["MetaStudyCore"])
    ]
)
