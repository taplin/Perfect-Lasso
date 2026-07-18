// swift-tools-version: 6.2
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
        .library(name: "LassoPerfectFileMaker", targets: ["LassoPerfectFileMaker"]),
        .executable(name: "lasso-subset-crawler", targets: ["LassoSubsetCrawler"]),
        .executable(name: "lasso-mysql-smoke", targets: ["LassoMySQLSmoke"]),
        .executable(name: "lasso-filemaker-smoke", targets: ["LassoFileMakerSmoke"]),
        .executable(name: "lasso-perfect-server", targets: ["LassoPerfectServer"]),
    ],
    dependencies: [
        .package(path: "../Perfect-Resurrection/Perfect-CRUD"),
        .package(path: "../Perfect-Resurrection/Perfect-MySQL"),
        .package(path: "../Perfect-Resurrection/Perfect-NIO"),
        .package(path: "../Perfect-Resurrection/Perfect-Session"),
        .package(path: "../Perfect-Resurrection/Perfect-FileMaker"),
        .package(path: "../Perfect-Resurrection/Perfect-FileMaker-AdminAPI"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.0"),
    ],
    targets: [
        .target(
            name: "LassoParser",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(name: "LassoCrawlReport"),
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
        .target(
            name: "LassoPerfectFileMaker",
            dependencies: [
                "LassoParser",
                .product(name: "PerfectFileMaker", package: "Perfect-FileMaker"),
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
            name: "LassoFileMakerSmoke",
            dependencies: [
                "LassoParser",
                "LassoPerfectFileMaker",
                .product(name: "PerfectFileMaker", package: "Perfect-FileMaker"),
            ]
        ),
        .executableTarget(
            name: "LassoPerfectServer",
            dependencies: [
                "LassoCrawlReport",
                "LassoParser",
                "LassoPerfectCRUD",
                "LassoPerfectSession",
                "LassoPerfectFileMaker",
                .product(name: "PerfectCRUD", package: "Perfect-CRUD"),
                .product(name: "PerfectMySQL", package: "Perfect-MySQL"),
                .product(name: "PerfectNIO", package: "Perfect-NIO"),
                .product(name: "PerfectSessionCore", package: "Perfect-Session"),
                .product(name: "PerfectSessionMySQL", package: "Perfect-Session"),
                .product(name: "PerfectFileMaker", package: "Perfect-FileMaker"),
                .product(name: "PerfectAdminConsole", package: "Perfect-NIO"),
                .product(name: "PerfectFileMakerAdminAPI", package: "Perfect-FileMaker-AdminAPI"),
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
            name: "LassoCrawlReportTests",
            dependencies: ["LassoCrawlReport"]
        ),
        .testTarget(
            name: "LassoPerfectServerTests",
            dependencies: [
                "LassoPerfectServer",
                "LassoParser",
                .product(name: "PerfectNIO", package: "Perfect-NIO"),
                .product(name: "PerfectAdminConsole", package: "Perfect-NIO"),
                .product(name: "PerfectFileMakerAdminAPI", package: "Perfect-FileMaker-AdminAPI"),
            ]
        ),
        .testTarget(
            name: "LassoParserTests",
            dependencies: [
                "LassoParser",
                "LassoPerfectCRUD",
                "LassoPerfectSession",
                "LassoPerfectFileMaker",
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
