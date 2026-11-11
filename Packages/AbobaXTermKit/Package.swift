// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AbobaXTermKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AXModels", targets: ["AXModels"]),
        .library(name: "AXStorage", targets: ["AXStorage"]),
        .library(name: "AXAskpassProtocol", targets: ["AXAskpassProtocol"]),
        .library(name: "AXSSH", targets: ["AXSSH"]),
        .library(name: "AXTerminal", targets: ["AXTerminal"]),
        .library(name: "AXSFTP", targets: ["AXSFTP"]),
        .library(name: "AXEditor", targets: ["AXEditor"]),
        .library(name: "AXX11", targets: ["AXX11"]),
        .library(name: "AXUI", targets: ["AXUI"]),
        .executable(name: "abx-askpass", targets: ["abx-askpass"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.20.0"),
    ],
    targets: [
        .target(name: "AXModels"),
        .target(name: "AXStorage", dependencies: ["AXModels"]),
        .target(name: "AXAskpassProtocol"),
        .target(name: "AXSSH", dependencies: ["AXModels", "AXStorage", "AXAskpassProtocol"]),
        .target(name: "AXTerminal", dependencies: ["AXModels", "AXSSH", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .target(name: "AXSFTP"),
        .target(name: "AXEditor"),
        .target(name: "AXX11"),
        .target(name: "AXUI", dependencies: ["AXModels", "AXStorage", "AXSSH", "AXTerminal", "AXSFTP", "AXEditor", "AXX11"]),
        // Development tool: runs the embedded X server against a local command and dumps window snapshots.
        .executableTarget(name: "abx-x11-harness", dependencies: ["AXX11"]),
        .executableTarget(name: "abx-askpass", dependencies: ["AXAskpassProtocol"]),
        .testTarget(name: "AXModelsTests", dependencies: ["AXModels"]),
        .testTarget(name: "AXStorageTests", dependencies: ["AXStorage", "AXModels"]),
        .testTarget(name: "AXSSHTests", dependencies: ["AXSSH", "AXModels"]),
        .testTarget(name: "AXTerminalTests", dependencies: ["AXTerminal"]),
        .testTarget(name: "AXSFTPTests", dependencies: ["AXSFTP"]),
        .testTarget(name: "AXEditorTests", dependencies: ["AXEditor"]),
        .testTarget(name: "AXX11Tests", dependencies: ["AXX11"]),
    ]
)
