// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LassoSubsetCrawler",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "LassoParser", targets: ["LassoParser"]),
        .library(name: "LassoPerfectCRUD", targets: ["LassoPerfectCRUD"]),
        .library(name: "LassoPerfectSession", targets: ["LassoPerfectSession"]),
        .executable(name: "lasso-subset-crawler", targets: ["LassoSubsetCrawler"]),
        .executable(name: "lasso-mysql-smoke", targets: ["LassoMySQLSmoke"]),
        .executable(name: "lasso-perfect-server", targets: ["LassoPerfectServer"]),
    ],
    dependencies: [
        .package(path: "../../Perfect-Resurrection/Perfect-CRUD"),
        .package(path: "../../Perfect-Resurrection/Perfect-MySQL"),
        .package(path: "../../Perfect-Resurrection/Perfect-NIO"),
        .package(path: "../../Perfect-Resurrection/Perfect-Session"),
    ],
    targets: [
        .target(name: "LassoParser"),
        .target(
            name: "LassoPerfectCRUD",
            dependencies: [
                "LassoParser",
                .product(name: "PerfectCRUD", package: "Perfect-CRUD"),
            ]
        ),
        .target(
            name: "LassoPerfectSession",
            dependencies: [
                "LassoParser",
                .product(name: "PerfectSessionCore", package: "Perfect-Session"),
            ]
        ),
        .executableTarget(
            name: "LassoParserSmoke",
            dependencies: ["LassoParser", "LassoPerfectCRUD"]
        ),
        .executableTarget(
            name: "LassoMySQLSmoke",
            dependencies: [
                "LassoParser",
                "LassoPerfectCRUD",
                .product(name: "PerfectCRUD", package: "Perfect-CRUD"),
                .product(name: "PerfectMySQL", package: "Perfect-MySQL"),
            ]
        ),
        .executableTarget(
            name: "LassoPerfectServer",
            dependencies: [
                "LassoParser",
                "LassoPerfectCRUD",
                "LassoPerfectSession",
                .product(name: "PerfectCRUD", package: "Perfect-CRUD"),
                .product(name: "PerfectMySQL", package: "Perfect-MySQL"),
                .product(name: "PerfectNIO", package: "Perfect-NIO"),
                .product(name: "PerfectSessionCore", package: "Perfect-Session"),
                .product(name: "PerfectSessionMySQL", package: "Perfect-Session"),
            ]
        ),
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "LassoSubsetCrawler",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "LassoSubsetCrawlerTests",
            dependencies: ["LassoSubsetCrawler"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "LassoParserTests",
            dependencies: [
                "LassoParser",
                "LassoPerfectCRUD",
                "LassoPerfectSession",
                .product(name: "PerfectSessionCore", package: "Perfect-Session"),
            ],
            resources: [.copy("Fixtures"), .copy("RenderFixtures"), .copy("CorpusFixtures")],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ],
    swiftLanguageModes: [.v6]
)
