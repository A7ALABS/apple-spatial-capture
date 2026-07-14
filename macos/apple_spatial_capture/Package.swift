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
        // Vendored msplat Gaussian-splatting training engine (Apache 2.0,
        // https://github.com/rayanht/msplat). Static C library over Metal.
        .binaryTarget(
            name: "MsplatCore",
            path: "MsplatCore.xcframework"
        ),
        .target(
            name: "apple_spatial_capture",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
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
