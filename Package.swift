// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Noodle",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Noodle", targets: ["Noodle"])
    ],
    targets: [
        .executableTarget(
            name: "Noodle",
            path: "Sources/Noodle"
        )
    ]
)
