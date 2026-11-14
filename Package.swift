// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Tesserae",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Tesserae",
            path: "Sources/Tesserae",
            swiftSettings: [.unsafeFlags(["-Ounchecked"])]
        )
    ]
)
