// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BuildChechenLexicon",
    targets: [
        .target(name: "ChechenLexiconCore"),
        .executableTarget(
            name: "BuildChechenLexicon",
            dependencies: ["ChechenLexiconCore"],
            path: "Sources/BuildChechenLexicon"
        ),
        .testTarget(
            name: "ChechenLexiconCoreTests",
            dependencies: ["ChechenLexiconCore"],
            path: "Tests/ChechenLexiconCoreTests"
        ),
    ]
)
