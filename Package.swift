// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LassoSubsetCrawler",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "LassoParser", targets: ["LassoParser"]),
        .library(name: "LassoPerfectCRUD", targets: ["LassoPerfectCRUD"]),
        .library(name: "LassoPerfectSession", targets: ["LassoPerfectSession"]),
        .library(name: "LassoPerfectFileMaker", targets: ["LassoPerfectFileMaker"]),
        .library(name: "LassoPerfectSMTP", targets: ["LassoPerfectSMTP"]),
        .executable(name: "lasso-subset-crawler", targets: ["LassoSubsetCrawler"]),
        .executable(name: "lasso-mysql-smoke", targets: ["LassoMySQLSmoke"]),
        .executable(name: "lasso-session-mysql-smoke", targets: ["LassoSessionMySQLSmoke"]),
        .executable(name: "lasso-filemaker-smoke", targets: ["LassoFileMakerSmoke"]),
        .executable(name: "lasso-perfect-server", targets: ["LassoPerfectServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/taplin/Perfect-CRUD.git", branch: "main"),
        .package(url: "https://github.com/taplin/Perfect-MySQL.git", branch: "main"),
        .package(url: "https://github.com/taplin/Perfect-NIO.git", branch: "main"),
        .package(url: "https://github.com/taplin/Perfect-Session.git", branch: "main"),
        .package(url: "https://github.com/taplin/Perfect-FileMaker.git", branch: "main"),
        .package(url: "https://github.com/taplin/Perfect-FileMaker-AdminAPI.git", branch: "main"),
        .package(url: "https://github.com/taplin/Perfect-SMTP.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
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
        .target(
            name: "LassoPerfectSMTP",
            dependencies: [
                "LassoParser",
                .product(name: "PerfectSMTP", package: "Perfect-SMTP"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
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
            name: "LassoSessionMySQLSmoke",
            dependencies: [
                "LassoParser",
                "LassoPerfectSession",
                .product(name: "PerfectSessionCore", package: "Perfect-Session"),
                .product(name: "PerfectSessionMySQL", package: "Perfect-Session"),
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
                "LassoPerfectSMTP",
                .product(name: "PerfectCRUD", package: "Perfect-CRUD"),
                .product(name: "PerfectMySQL", package: "Perfect-MySQL"),
                .product(name: "PerfectNIO", package: "Perfect-NIO"),
                .product(name: "PerfectSessionCore", package: "Perfect-Session"),
                .product(name: "PerfectSessionMySQL", package: "Perfect-Session"),
                .product(name: "PerfectFileMaker", package: "Perfect-FileMaker"),
                .product(name: "PerfectAdminConsole", package: "Perfect-NIO"),
                .product(name: "PerfectFileMakerAdminAPI", package: "Perfect-FileMaker-AdminAPI"),
                .product(name: "PerfectSMTP", package: "Perfect-SMTP"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
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
        .testTarget(
            name: "LassoPerfectSMTPTests",
            dependencies: [
                "LassoParser",
                "LassoPerfectSMTP",
                .product(name: "PerfectSMTP", package: "Perfect-SMTP"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
