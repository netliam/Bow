// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BowKit",
    platforms: [
        .iOS("27.2"),
        .macCatalyst("27.2"),
        // Only so `swift test` can run on the Mac host. The app ships as Mac Catalyst (ADR-0001).
        .macOS("27.2"),
    ],
    products: [
        .library(name: "BowModel", targets: ["BowModel"]),
        .library(name: "GrimmoryAPI", targets: ["GrimmoryAPI"]),
        .library(name: "BowSync", targets: ["BowSync"]),
        .library(name: "BowLibrary", targets: ["BowLibrary"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.13.4"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.20"),
    ],
    targets: [
        .target(name: "BowModel"),
        .target(
            name: "GrimmoryAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            exclude: ["openapi.json", "openapi-generator-config.yaml"]
        ),
        .target(name: "BowSync", dependencies: ["BowModel", "GrimmoryAPI"]),
        .target(
            name: "BowLibrary",
            dependencies: ["BowModel", "GrimmoryAPI", .product(name: "ZIPFoundation", package: "ZIPFoundation")]
        ),
        .testTarget(name: "BowModelTests", dependencies: ["BowModel"]),
        .testTarget(name: "BowSyncTests", dependencies: ["BowSync", "BowModel", "GrimmoryAPI"]),
        .testTarget(
            name: "BowLibraryTests",
            dependencies: ["BowLibrary", "BowModel", .product(name: "ZIPFoundation", package: "ZIPFoundation")]
        ),
        .testTarget(
            name: "GrimmoryAPITests",
            dependencies: [
                "GrimmoryAPI",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
    ]
)
