// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LogoLight",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LogoLight", targets: ["LogoLight"]),
    ],
    targets: [
        // Hardware access and privileged commands. No UI code lives here.
        .target(
            name: "LogoLightCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // The menu bar app.
        .executableTarget(
            name: "LogoLight",
            dependencies: ["LogoLightCore"]
        ),
        // Self-contained test runner (`swift run LogoLightTests`).
        // XCTest and swift-testing are only available with a full Xcode install,
        // so this keeps the project buildable and testable with the Command Line Tools alone.
        .executableTarget(
            name: "LogoLightTests",
            dependencies: ["LogoLightCore"]
        ),
    ]
)
