// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "GreetingService",
    platforms: [
        .macOS(.v10_15)
    ],
    targets: [
        .executableTarget(
            name: "GreetingService"
        )
    ]
)
