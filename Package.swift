// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "RoomTwinCore", platforms: [.iOS(.v17), .macOS(.v13)], products: [.library(name: "RoomTwinCore", targets: ["RoomTwinCore"])], targets: [.target(name: "RoomTwinCore", path: "Sources/Core"), .testTarget(name: "CoreTests", dependencies: ["RoomTwinCore"], path: "Tests/CoreTests")])
