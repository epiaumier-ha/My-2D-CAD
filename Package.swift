// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "My2DCAD",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "My2DCAD",
            path: "Sources/My2DCAD"
        ),
        .testTarget(
            name: "My2DCADTests",
            dependencies: ["My2DCAD"],
            path: "Tests/My2DCADTests"
        ),
    ]
)
