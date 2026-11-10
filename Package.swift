// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MonoSplit",
    platforms: [.macOS("15.4")],
    products: [
        .library(name: "MonoSplitCore", targets: ["MonoSplitCore"]),
        .executable(name: "MonoSplit", targets: ["MonoSplit"])
    ],
    targets: [
        .target(name: "MonoSplitDSP", publicHeadersPath: "include"),
        .target(name: "MonoSplitCore", dependencies: ["MonoSplitDSP"]),
        .executableTarget(name: "MonoSplit", dependencies: ["MonoSplitCore", "MonoSplitDSP"]),
        .testTarget(name: "MonoSplitCoreTests", dependencies: ["MonoSplitCore", "MonoSplitDSP"]),
        .testTarget(name: "MonoSplitAppTests", dependencies: ["MonoSplit", "MonoSplitCore"])
    ],
    cxxLanguageStandard: .cxx17
)
