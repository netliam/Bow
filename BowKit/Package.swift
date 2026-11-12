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
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.13.4"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0"),
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
        .testTarget(name: "BowModelTests", dependencies: ["BowModel"]),
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
