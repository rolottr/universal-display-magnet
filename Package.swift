// swift-tools-version: 6.0
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "UniversalDisplayMagnet",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "UniversalDisplayMagnet", targets: ["UniversalDisplayMagnet"]),
        .library(name: "UniversalDisplayMagnetCore", targets: ["UniversalDisplayMagnetCore"]),
    ],
    targets: [
        // Pure, hardware-free logic: layout math, display identity, window
        // matching, sync records and the wire protocol. Fully unit-tested.
        .target(
            name: "UniversalDisplayMagnetCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The menu bar app: CoreGraphics, Accessibility, Spaces, Bonjour, UI.
        .executableTarget(
            name: "UniversalDisplayMagnet",
            dependencies: ["UniversalDisplayMagnetCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // Hand-written interface for the private UniversalControl framework.
                .unsafeFlags(["-I", "\(root)/UniversalControlInterface"]),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                // Linked against a stub listing only the symbols Universal Display Magnet
                // uses (no SDK private-framework stubs needed); weak, so the
                // app still launches if a future macOS drops the framework.
                .unsafeFlags([
                    "-F", "\(root)/UniversalControlInterface/Frameworks",
                    "-Xlinker", "-weak_framework", "-Xlinker", "UniversalControl",
                ]),
            ]
        ),
        .testTarget(
            name: "UniversalDisplayMagnetCoreTests",
            dependencies: ["UniversalDisplayMagnetCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
