// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "__CARTRIDGE_NAME__",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/machinefabric/capdag-objc.git", from: "1.454.20"),
        .package(url: "https://github.com/jowharshamshiri/ops-objc.git", from: "1.19.17"),
    ],
    targets: [
        .executableTarget(
            name: "__CARTRIDGE_NAME__",
            dependencies: [
                .product(name: "Bifaci", package: "capdag-objc"),
                .product(name: "CapDAG", package: "capdag-objc"),
                .product(name: "Ops", package: "ops-objc"),
            ],
            path: "Sources"
        )
    ]
)
