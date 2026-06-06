// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "apple_spatial_capture",
    platforms: [
        .macOS("12.0")
    ],
    products: [
        .library(name: "apple-spatial-capture", targets: ["apple_spatial_capture"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "apple_spatial_capture",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
