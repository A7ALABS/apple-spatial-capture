// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "apple_spatial_capture",
    platforms: [
        .iOS("14.0")
    ],
    products: [
        .library(name: "apple-spatial-capture", targets: ["apple_spatial_capture"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(url: "https://github.com/magicien/GLTFSceneKit", from: "0.3.0")
    ],
    targets: [
        .target(
            name: "apple_spatial_capture",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "GLTFSceneKit", package: "GLTFSceneKit")
            ]
        )
    ]
)
