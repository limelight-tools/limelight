// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Limelight",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .executable(
            name: "Limelight",
            targets: ["Limelight"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Limelight"
        )
    ]
)
