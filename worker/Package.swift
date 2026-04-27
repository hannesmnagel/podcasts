// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PodcastWorker",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PodcastWorker", targets: ["PodcastWorker"]),
    ],
    targets: [
        .executableTarget(name: "PodcastWorker", swiftSettings: [
            .enableUpcomingFeature("ExistentialAny"),
            .enableExperimentalFeature("StrictConcurrency")
        ]),
        .testTarget(name: "PodcastWorkerTests", dependencies: ["PodcastWorker"])
    ]
)
