// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MImago",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MImago", targets: ["MImago"])
    ],
    dependencies: [
        .package(path: "../FormaUI/components/FormaUI")
    ],
    targets: [
        .executableTarget(
            name: "MImago",
            dependencies: [
                .product(name: "FormaUI", package: "FormaUI")
            ],
            resources: [.process("Resources")]
        )
    ]
)
