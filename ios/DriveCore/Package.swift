// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "HarnessDriveCore",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [.library(name: "HarnessDriveCore", targets: ["HarnessDriveCore"])],
  targets: [
    .target(name: "HarnessDriveCore"),
    .testTarget(name: "HarnessDriveCoreTests", dependencies: ["HarnessDriveCore"])
  ]
)
