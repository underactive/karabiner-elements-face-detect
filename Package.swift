// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FaceProfile",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "FaceProfileLib",
            path: ".",
            sources: [
                "ProfileStateMachine.swift",
                "FaceProfileDaemon.swift",
                "FacePresenceDetector.swift",
            ]
        ),
        .testTarget(
            name: "FaceProfileTests",
            dependencies: ["FaceProfileLib"],
            path: "Tests"
        ),
    ]
)
