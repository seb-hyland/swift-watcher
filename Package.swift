// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-watcher",
    dependencies: [
        .package(url: "https://github.com/marksands/BetterCodable.git", from: "0.4.0"),
        .package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.4"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(
            url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.7.0"
        ),
        .package(url: "https://github.com/mhayes853/swift-uuidv7", from: "0.6.1"),
        .package(
            url: "https://github.com/swiftlang/swift-subprocess.git", .upToNextMinor(from: "0.4.0")
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "SwiftWatcher",
            dependencies: [
                .product(name: "BetterCodable", package: "bettercodable"),
                .product(name: "TOMLDecoder", package: "tomldecoder"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "UUIDV7", package: "swift-uuidv7"),
                .product(name: "Subprocess", package: "swift-subprocess"),
            ],
            exclude: ["Web/main.ts", "Web/ansi_up.ts"],
            resources: [.embedInCode("Web/build.html")],
            plugins: ["TsBundler"],
        ),

        .plugin(
            name: "TsBundler",
            capability: .buildTool(),
            dependencies: ["TsBundleGen"]
        ),

        .executableTarget(
            name: "TsBundleGen",
            dependencies: [.product(name: "Subprocess", package: "swift-subprocess")],
        ),
    ],
    swiftLanguageModes: [.v6]
)
