// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EnglishCorrect",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EnglishCorrect", targets: ["EnglishCorrect"]),
        .library(name: "EnglishCorrectCore", targets: ["EnglishCorrectCore"])
    ],
    targets: [
        .target(name: "EnglishCorrectCore"),
        .executableTarget(name: "EnglishCorrect", dependencies: ["EnglishCorrectCore"], resources: [.copy("Resources/Credits")]),
        .testTarget(name: "EnglishCorrectCoreTests", dependencies: ["EnglishCorrectCore"]),
        .testTarget(name: "EnglishCorrectAppTests", dependencies: ["EnglishCorrect", "EnglishCorrectCore"])
    ],
    swiftLanguageModes: [.v5]
)
