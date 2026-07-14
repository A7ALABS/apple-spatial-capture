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
        // Vendored msplat Gaussian-splatting training engine (Apache 2.0,
        // https://github.com/rayanht/msplat). Static C library over Metal.
        // iOS slice is experimental — training support is gated at runtime.
        .binaryTarget(
            name: "MsplatCore",
            path: "MsplatCore.xcframework"
        ),
        .target(
            name: "apple_spatial_capture",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "GLTFSceneKit", package: "GLTFSceneKit"),
                "MsplatCore"
            ],
            resources: [
                .copy("Resources/default.metallib")
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("MetalPerformanceShaders"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreGraphics")
            ]
        )
    ]
)
