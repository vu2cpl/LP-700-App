// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LP-700-App",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "LP-700-App", targets: ["LP700App"]),
    ],
    targets: [
        .executableTarget(
            name: "LP700App",
            path: "Sources/LP700App"
        ),
        .testTarget(
            name: "LP700AppTests",
            dependencies: ["LP700App"],
            path: "Tests/LP700AppTests"
        ),
    ]
)
