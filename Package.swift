// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "KeepAwake",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "KeepAwake", targets: ["KeepAwake"])
    ],
    targets: [
        .executableTarget(
            name: "KeepAwake",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
