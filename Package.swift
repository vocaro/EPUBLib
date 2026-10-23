// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EPUBLib",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "EPUBCore", targets: ["EPUBCore"]),
        .library(name: "EPUBReading", targets: ["EPUBReading"]),
        .library(name: "EPUBText", targets: ["EPUBText"]),
        .library(name: "EPUBWriting", targets: ["EPUBWriting"]),
        .library(name: "EPUBViewing", targets: ["EPUBViewing"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(url: "https://github.com/vocaro/MathMLLayout.git", exact: "0.3.1"),
        .package(url: "https://github.com/vocaro/StaticSVG.git", exact: "0.1.1"),
    ],
    targets: [
        .executableTarget(name: "SearchFocusProbe", dependencies: ["EPUBCore", "EPUBReading", "EPUBViewing", "EPUBTestSupport"], path: "Examples/SearchFocusProbe"),
        // The license and notice texts a host shows in its acknowledgments, under their projects' names.
        .target(name: "EPUBCore", resources: [.copy("Licenses")]),
        .target(name: "EPUBReading", dependencies: ["EPUBCore", "ZIPFoundation"]),
        .target(name: "EPUBText", dependencies: ["EPUBCore", "EPUBReading"]),
        .target(name: "EPUBWriting", dependencies: ["EPUBCore", "ZIPFoundation"]),
        .target(name: "EPUBViewing", dependencies: ["EPUBCore", "EPUBReading",
                                                    .product(name: "MathMLLayout", package: "MathMLLayout"),
                                                    .product(name: "StaticSVG", package: "StaticSVG")]),
        .target(name: "EPUBViewingTestSupport", dependencies: ["EPUBCore", "EPUBReading", "EPUBViewing"]),
        .target(name: "EPUBTestSupport", dependencies: ["ZIPFoundation"], path: "Tests/EPUBTestSupport"),
        .target(name: "ReaderHostSupport", dependencies: ["EPUBCore", "EPUBReading", "EPUBText", "EPUBViewing"],
                path: "Examples/VoiceOverVerification/Shared"),
        .testTarget(name: "EPUBReadingTests", dependencies: ["EPUBCore", "EPUBReading", "EPUBText", "EPUBTestSupport"]),
        .testTarget(name: "EPUBWritingTests", dependencies: ["EPUBCore", "EPUBWriting", "EPUBReading", "EPUBText", "ZIPFoundation"]),
        .testTarget(name: "EPUBViewingTests", dependencies: ["EPUBCore", "EPUBReading", "EPUBViewing", "EPUBViewingTestSupport", "EPUBTestSupport",
                                                            .product(name: "StaticSVG", package: "StaticSVG")]),
    ]
)
