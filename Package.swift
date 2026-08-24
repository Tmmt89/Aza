// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Aza",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Aza", targets: ["Aza"])
    ],
    targets: [
        .executableTarget(name: "Aza", resources: [.process("Resources")])
    ]
)
