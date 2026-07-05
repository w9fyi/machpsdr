// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FT8Kit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FT8Kit", targets: ["FT8Kit"])
    ],
    targets: [
        .target(
            name: "CFT8",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("include/ft8"),
                .headerSearchPath("include/fft"),
                .headerSearchPath("include/common"),
                .unsafeFlags(["-w"])
            ]
        ),
        .target(
            name: "FT8Kit",
            dependencies: ["CFT8"]
        ),
        .testTarget(
            name: "FT8KitTests",
            dependencies: ["FT8Kit"]
        )
    ]
)
