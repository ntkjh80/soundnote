// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SoriNote",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SoriNote", targets: ["SoriNote"])],
    targets: [
        .executableTarget(name: "SoriNote"),
        .testTarget(name: "SoriNoteTests", dependencies: ["SoriNote"])
    ]
)
