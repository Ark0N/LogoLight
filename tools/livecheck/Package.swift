// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "LogoLightLiveTest", platforms: [.macOS(.v14)],
  targets: [
    .target(name: "LogoLightCore", linkerSettings: [.linkedFramework("IOKit")]),
    .executableTarget(name: "LogoLightLiveTest", dependencies: ["LogoLightCore"])])
