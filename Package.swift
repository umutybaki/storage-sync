// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "StorageSync",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "StorageSyncCore", targets: ["StorageSyncCore"]),
        .library(name: "StorageSyncPersistence", targets: ["StorageSyncPersistence"]),
        .library(name: "StorageSyncS3", targets: ["StorageSyncS3"]),
        .library(name: "StorageSyncSystem", targets: ["StorageSyncSystem"]),
        .library(name: "StorageSyncShared", targets: ["StorageSyncShared"]),
        .library(name: "StorageSyncEngine", targets: ["StorageSyncEngine"]),
        .executable(name: "StorageSync", targets: ["StorageSyncApp"]),
        .executable(name: "StorageSyncAgent", targets: ["StorageSyncAgent"]),
        .executable(name: "storagesynctest", targets: ["StorageSyncTestRunner"])
    ],
    targets: [
        .target(name: "StorageSyncCore"),
        .target(
            name: "StorageSyncPersistence",
            dependencies: ["StorageSyncCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "StorageSyncS3", dependencies: ["StorageSyncCore"]),
        .target(
            name: "StorageSyncSystem",
            dependencies: ["StorageSyncCore"],
            linkerSettings: [.linkedFramework("DiskArbitration")]
        ),
        .target(name: "StorageSyncShared", dependencies: ["StorageSyncCore"]),
        .target(
            name: "StorageSyncEngine",
            dependencies: [
                "StorageSyncCore",
                "StorageSyncPersistence",
                "StorageSyncS3",
                "StorageSyncSystem"
            ]
        ),
        .executableTarget(
            name: "StorageSyncAgent",
            dependencies: [
                "StorageSyncCore",
                "StorageSyncPersistence",
                "StorageSyncS3",
                "StorageSyncSystem",
                "StorageSyncShared",
                "StorageSyncEngine"
            ]
        ),
        .executableTarget(
            name: "StorageSyncApp",
            dependencies: ["StorageSyncCore", "StorageSyncShared", "StorageSyncSystem"]
        ),
        .executableTarget(
            name: "StorageSyncTestRunner",
            dependencies: ["StorageSyncCore", "StorageSyncPersistence", "StorageSyncS3", "StorageSyncSystem", "StorageSyncEngine"]
        )
    ]
)
