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
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .target(name: "EPUBCore"),
        .target(name: "EPUBReading", dependencies: ["EPUBCore", "ZIPFoundation"]),
        .target(name: "EPUBText", dependencies: ["EPUBCore", "EPUBReading"]),
        .target(name: "EPUBWriting", dependencies: ["EPUBCore", "ZIPFoundation"]),
        .target(name: "MathMLLayout"),
        .target(name: "EPUBViewing", dependencies: ["EPUBCore", "EPUBReading", "MathMLLayout"],
                resources: [.copy("Resources/epub-reader")]),
        .target(name: "EPUBViewingTestSupport", dependencies: ["EPUBCore", "EPUBReading", "EPUBViewing"]),
        .target(name: "EPUBTestSupport", dependencies: ["ZIPFoundation"], path: "Tests/EPUBTestSupport"),
        .target(name: "ReaderSampleSupport", dependencies: ["EPUBCore", "EPUBReading", "EPUBText", "EPUBViewing"],
                path: "Examples/ReaderSample/Shared"),
        .testTarget(name: "EPUBReadingTests", dependencies: ["EPUBCore", "EPUBReading", "EPUBText", "EPUBTestSupport"]),
        .testTarget(name: "EPUBWritingTests", dependencies: ["EPUBCore", "EPUBWriting", "EPUBReading", "EPUBText", "ZIPFoundation"]),
        .testTarget(name: "EPUBViewingTests", dependencies: ["EPUBCore", "EPUBReading", "EPUBViewing", "EPUBViewingTestSupport", "EPUBTestSupport"]),
    ]
)
