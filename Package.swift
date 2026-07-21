// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Conduit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Conduit", targets: ["Conduit"]),
        .executable(name: "conduit-selftest", targets: ["ConduitSelfTest"]),
        .library(name: "ConduitCore", targets: ["ConduitCore"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            revision: "58915b1010d7dbc86d0e79dc2c40f0c183ccaf5b"
        )
    ],
    targets: [
        .target(name: "ConduitCore"),
        .executableTarget(
            name: "ConduitSelfTest",
            dependencies: ["ConduitCore"]
        ),
        .executableTarget(
            name: "Conduit",
            dependencies: [
                "ConduitCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            exclude: ["Resources/Info.plist"]
        ),
        .testTarget(
            name: "ConduitCoreTests",
            dependencies: ["ConduitCore"]
        )
    ]
)
