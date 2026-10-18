// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RoomTwinCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "RoomTwinCore", targets: ["RoomTwinCore"])],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(name: "RoomTwinCore", dependencies: ["CSQLite"], path: "Sources/Core"),
        .testTarget(name: "CoreTests", dependencies: ["RoomTwinCore"], path: "Tests/CoreTests")
    ]
)
