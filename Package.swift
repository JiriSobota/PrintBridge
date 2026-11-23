// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PrintBridge",
    defaultLocalization: "cs",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PrintBridge", targets: ["PrintBridge"]),
    ],
    targets: [
        .target(
            name: "BrotherKit",
            path: "Sources/BrotherKit",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
                .linkedFramework("Network"),
            ]
        ),
        .executableTarget(
            name: "PrintBridge",
            dependencies: ["BrotherKit"],
            path: "Sources/PrintBridge"
        ),
        .executableTarget(
            name: "pbctl",
            dependencies: ["BrotherKit"],
            path: "Sources/pbctl"
        ),
        .executableTarget(
            name: "BrotherKitSelfTest",
            dependencies: ["BrotherKit"],
            path: "Sources/BrotherKitSelfTest"
        ),
    ]
)
