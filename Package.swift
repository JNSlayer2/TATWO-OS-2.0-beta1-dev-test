// swift-tools-version: 6.1
import PackageDescription
import Foundation

let environment = ProcessInfo.processInfo.environment
let cefBuildSwitch = environment["TATWO_ENABLE_CEF"] ?? "0"
guard cefBuildSwitch == "0" || cefBuildSwitch == "1" else {
    fatalError("TATWO_ENABLE_CEF must be exactly 0 or 1")
}
let cefBuildRequested = cefBuildSwitch == "1"
let cefRuntimeTestOnlySwitch =
    environment["TATWO_CEF_RUNTIME_TEST_ONLY"] ?? "0"
guard cefRuntimeTestOnlySwitch == "0"
        || cefRuntimeTestOnlySwitch == "1"
else {
    fatalError("TATWO_CEF_RUNTIME_TEST_ONLY must be exactly 0 or 1")
}
let cefRuntimeTestOnly = cefRuntimeTestOnlySwitch == "1"
if cefRuntimeTestOnly && !cefBuildRequested {
    fatalError("TATWO_CEF_RUNTIME_TEST_ONLY=1 requires TATWO_ENABLE_CEF=1")
}
let cefRoot = environment["TATWO_CEF_ROOT"] ?? ""
let cefWrapperLibrary = environment["TATWO_CEF_WRAPPER_LIBRARY"] ?? ""
if cefBuildRequested {
    let requiredCEFPaths = [
        "\(cefRoot)/include/cef_app.h",
        "\(cefRoot)/Release/Chromium Embedded Framework.framework",
        cefWrapperLibrary,
    ]
    guard !cefRoot.isEmpty,
          !cefWrapperLibrary.isEmpty,
          requiredCEFPaths.allSatisfy({
              FileManager.default.fileExists(atPath: $0)
          })
    else {
        fatalError(
            "TATWO_ENABLE_CEF=1 requires a verified TATWO_CEF_ROOT "
                + "and TATWO_CEF_WRAPPER_LIBRARY")
    }
}
let cefBuildEnabled = cefBuildRequested

let cefBridgeSources = cefBuildEnabled
    ? ["TatwoCEFBridge.mm"]
    : ["TatwoCEFBridgeUnavailable.m"]
let macTestSources: [String]? = cefRuntimeTestOnly
    ? [
        "ChromiumCEFSecurityPolicyTests.swift",
        "ChromiumCEFSessionIsolationTests.swift",
        "WebMCPOriginParsingTests.swift",
    ]
    : nil
let macTestResources: [Resource] = cefRuntimeTestOnly
    ? []
    : [
        .copy("Fixtures/claude-usage-probe.json"),
        .copy("Fixtures/claude-dev-stream.jsonl"),
        .copy("Fixtures/browser-agent-attack-corpus.html"),
    ]
let cefBridgeCXXSettings: [CXXSetting] = cefBuildEnabled
    ? [
        .unsafeFlags([
            "-I\(cefRoot)",
            "-DUSING_CEF_SHARED",
            "-std=c++20",
            "-fno-exceptions",
            "-fno-rtti",
            "-fno-threadsafe-statics",
            "-fobjc-call-cxx-cdtors",
            "-Wno-narrowing",
            "-Wno-undefined-var-template",
        ])
    ]
    : []
let cefBridgeLinkerSettings: [LinkerSetting] = cefBuildEnabled
    ? [
        .unsafeFlags([
            cefWrapperLibrary,
            "-F\(cefRoot)/Release",
            "-framework", "Chromium Embedded Framework",
            "-Xlinker", "-ObjC",
            "-Xlinker", "-rpath",
            "-Xlinker", "@executable_path/../Frameworks",
            "-Xlinker", "-rpath",
            "-Xlinker", "@executable_path/../../..",
        ]),
        .linkedFramework("AppKit"),
        .linkedFramework("Cocoa"),
        .linkedFramework("IOSurface"),
    ]
    : [
        .linkedFramework("AppKit"),
    ]

let package = Package(
    name: "TatwoUltrawork",
    platforms: [
        .macOS(.v14),
        .iOS(.v18),
        .visionOS(.v2)
    ],
    products: [
        .library(name: "AISwitchCore", targets: ["AISwitchCore"]),
        .library(name: "AISwitchProviders", targets: ["AISwitchProviders"]),
        .library(name: "TatwoModuleContracts", targets: ["TatwoModuleContracts"]),
        .library(name: "TatwoWorkReceiptContracts", targets: ["TatwoWorkReceiptContracts"]),
        .library(name: "TatwoDomainContracts", targets: ["TatwoDomainContracts"]),
        .library(name: "TatwoDeploymentPrimitives", targets: ["TatwoDeploymentPrimitives"]),
        .library(name: "TatwoBootstrapCore", targets: ["TatwoBootstrapCore"]),
        .library(name: "TatwoUpdater", targets: ["TatwoUpdater"]),
        .library(name: "TatwoDeviceSyncCore", targets: ["TatwoDeviceSyncCore"]),
        .library(name: "TatwoRunnerAdapter", targets: ["TatwoRunnerAdapter"]),
        .library(name: "TatwoHostDaemon", targets: ["TatwoHostDaemon"]),
        .library(name: "TatwoUltraworkCore", targets: ["TatwoUltraworkCore"]),
        .executable(name: "tatwo-ultrawork", targets: ["TatwoUltraworkCLI"]),
        .executable(name: "tatwo-ar-race-helper", targets: ["tatwo-ar-race-helper"]),
        .executable(name: "agent-kernel-driver", targets: ["AgentKernelDriver"]),
        .executable(name: "g2c-kernel-exam", targets: ["G2CKernelExam"]),
        .executable(name: "TatwoCEFHelper", targets: ["TatwoCEFHelper"]),
        .executable(name: "TatwoUltraworkMac", targets: ["TatwoUltraworkMac"]),
        .executable(name: "Tatwo2", targets: ["Tatwo2"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.19.0"),
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.4"
        )
    ],
    targets: [
        .target(name: "AISwitchCore", path: "Packages/AISwitchCore/Sources/AISwitchCore"),
        .target(name: "AISwitchProviders", dependencies: ["AISwitchCore"], path: "Packages/AISwitchProviders/Sources/AISwitchProviders"),
        .target(
            name: "TatwoModuleContracts",
            path: "Packages/TatwoModuleContracts/Sources/TatwoModuleContracts"
        ),
        .target(
            name: "TatwoWorkReceiptContracts",
            path: "Packages/TatwoWorkReceiptContracts/Sources/TatwoWorkReceiptContracts"
        ),
        .target(
            name: "TatwoDomainContracts",
            dependencies: ["TatwoWorkReceiptContracts"],
            path: "Packages/TatwoDomainContracts/Sources/TatwoDomainContracts"
        ),
        .target(
            name: "TatwoDeploymentPrimitives",
            dependencies: ["TatwoModuleContracts"],
            path: "Packages/TatwoDeploymentPrimitives/Sources/TatwoDeploymentPrimitives"
        ),
        .target(
            name: "TatwoBootstrapCore",
            dependencies: ["TatwoModuleContracts", "TatwoDeploymentPrimitives"],
            path: "Packages/TatwoBootstrapCore/Sources/TatwoBootstrapCore"
        ),
        .target(
            name: "TatwoUpdater",
            dependencies: ["TatwoModuleContracts", "TatwoDeploymentPrimitives"],
            path: "Packages/TatwoUpdater/Sources/TatwoUpdater"
        ),
        .target(
            name: "TatwoDeviceSyncCore",
            dependencies: ["TatwoDomainContracts", "TatwoWorkReceiptContracts"],
            path: "Packages/TatwoDeviceSyncCore/Sources/TatwoDeviceSyncCore"
        ),
        .target(
            name: "TatwoRunnerAdapter",
            dependencies: ["TatwoWorkReceiptContracts"],
            path: "Packages/TatwoRunnerAdapter/Sources/TatwoRunnerAdapter"
        ),
        .target(
            name: "TatwoHostDaemon",
            dependencies: ["TatwoRunnerAdapter", "TatwoWorkReceiptContracts"],
            path: "Packages/TatwoHostDaemon/Sources/TatwoHostDaemon"
        ),
        .target(
            name: "TatwoUltraworkCore",
            dependencies: ["TatwoWorkReceiptContracts", "TatwoDomainContracts"],
            path: "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore",
            resources: [
                .copy("TatwoModelIdentityRegistryV1.json"),
                .copy("../../../../config/tatwo-sync-catalog-v1.json"),
                .copy("../../../../config/tatwo-durable-surface-inventory-v1.json"),
                .copy("../../../../config/sync-modules.v1.json")
            ]
        ),
        .target(
            name: "TatwoUltraworkTestSupport",
            dependencies: ["TatwoUltraworkCore"],
            path: "Packages/TatwoUltraworkTestSupport/Sources/TatwoUltraworkTestSupport"
        ),
        .target(
            name: "TatwoCEFBridge",
            path: "Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge",
            sources: cefBridgeSources,
            publicHeadersPath: "include",
            cxxSettings: cefBridgeCXXSettings,
            linkerSettings: cefBridgeLinkerSettings
        ),
        .executableTarget(
            name: "TatwoCEFHelper",
            dependencies: ["TatwoCEFBridge"],
            path: "Apps/TatwoUltraworkMac/Sources/TatwoCEFHelper"
        ),
        .executableTarget(
            name: "TatwoUltraworkCLI",
            dependencies: [
                "TatwoUltraworkCore",
                "TatwoModuleContracts",
                "TatwoDeploymentPrimitives",
                "TatwoBootstrapCore"
            ],
            path: "Tools/TatwoUltraworkCLI/Sources/TatwoUltraworkCLI"
        ),
        .executableTarget(
            name: "tatwo-ar-race-helper",
            dependencies: ["TatwoUltraworkCore"],
            path: "Tools/TatwoAntiRollbackRaceHelper/Sources"
        ),
        .executableTarget(
            name: "AgentKernelDriver",
            dependencies: ["TatwoUltraworkCore"],
            path: "Tools/AgentKernelDriver",
            exclude: [
                "selftest-resume.sh",
                "selftest-handoff.sh",
                "selftest-context.sh",
                "selftest-checkpoint-handoff.sh"
            ]
        ),
        .executableTarget(
            name: "G2CKernelExam",
            dependencies: ["TatwoUltraworkCore"],
            path: "Tools/G2CKernelExam"
        ),
        .executableTarget(
            name: "Tatwo2",
            dependencies: ["TatwoCEFBridge", .product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "App/Sources/Tatwo2",
            resources: [
                .process("Resources/ProviderIcons"),
                .copy("Resources/os-upstream.md"),
                .copy("Resources/os.md"),
                .copy("Resources/tatwo2-git-credential"),
                // W96：技能隨 App 出貨。正本是 repo 的 skills/tatwo-ultrawork/，
                // 直接打包那兩項，不在 Resources/ 再放一份會走樣的複本；
                // references/ 是私人封存，逐項列出就不會被帶進去。
                .copy("../../../skills/tatwo-ultrawork/SKILL.md"),
                .copy("../../../skills/tatwo-ultrawork/agents")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TatwoUltraworkMac",
            dependencies: [
                "TatwoUltraworkCore",
                "AISwitchCore",
                "AISwitchProviders",
                "TatwoModuleContracts",
                "TatwoWorkReceiptContracts",
                "TatwoDomainContracts",
                "TatwoDeploymentPrimitives",
                "TatwoBootstrapCore",
                "TatwoUpdater",
                "TatwoDeviceSyncCore",
                "TatwoCEFBridge",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac",
            resources: [
                .process("Resources/ProviderIcons"),
                .copy("Resources/BrowserBlocklists"),
                .copy("../../Resources/os-architecture-standard.md"),
                .copy("../../Resources/tab-design-philosophy.md"),
                .copy("../../../../scripts/tatwo-direct-gateway-chat.mjs"),
                .copy("../../../../scripts/tatwo-computer-mcp.mjs"),
                .copy("../../../../scripts/tatwo-app-mcp.mjs")
            ]
        ),
        .testTarget(
            name: "Tatwo2Tests",
            dependencies: ["Tatwo2"],
            path: "App/Tests/Tatwo2Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "AISwitchCoreTests", dependencies: ["AISwitchCore", "AISwitchProviders"], path: "Packages/AISwitchCore/Tests/AISwitchCoreTests"),
        .testTarget(
            name: "TatwoModuleContractsTests",
            dependencies: ["TatwoModuleContracts"],
            path: "Packages/TatwoModuleContracts/Tests/TatwoModuleContractsTests"
        ),
        .testTarget(
            name: "TatwoWorkReceiptContractsTests",
            dependencies: ["TatwoWorkReceiptContracts"],
            path: "Packages/TatwoWorkReceiptContracts/Tests/TatwoWorkReceiptContractsTests"
        ),
        .testTarget(
            name: "TatwoDomainContractsTests",
            dependencies: ["TatwoDomainContracts", "TatwoWorkReceiptContracts"],
            path: "Packages/TatwoDomainContracts/Tests/TatwoDomainContractsTests"
        ),
        .testTarget(
            name: "TatwoDeploymentPrimitivesTests",
            dependencies: ["TatwoDeploymentPrimitives", "TatwoModuleContracts"],
            path: "Packages/TatwoDeploymentPrimitives/Tests/TatwoDeploymentPrimitivesTests"
        ),
        .testTarget(
            name: "TatwoBootstrapCoreTests",
            dependencies: [
                "TatwoBootstrapCore",
                "TatwoModuleContracts",
                "TatwoDeploymentPrimitives"
            ],
            path: "Packages/TatwoBootstrapCore/Tests/TatwoBootstrapCoreTests"
        ),
        .testTarget(
            name: "TatwoUpdaterTests",
            dependencies: ["TatwoUpdater", "TatwoModuleContracts", "TatwoDeploymentPrimitives"],
            path: "Packages/TatwoUpdater/Tests/TatwoUpdaterTests"
        ),
        .testTarget(
            name: "TatwoDeviceSyncCoreTests",
            dependencies: [
                "TatwoDeviceSyncCore",
                "TatwoDomainContracts",
                "TatwoWorkReceiptContracts"
            ],
            path: "Packages/TatwoDeviceSyncCore/Tests/TatwoDeviceSyncCoreTests"
        ),
        .testTarget(
            name: "TatwoRunnerAdapterTests",
            dependencies: ["TatwoRunnerAdapter"],
            path: "Packages/TatwoRunnerAdapter/Tests/TatwoRunnerAdapterTests"
        ),
        .testTarget(
            name: "TatwoHostDaemonTests",
            dependencies: ["TatwoHostDaemon", "TatwoRunnerAdapter"],
            path: "Packages/TatwoHostDaemon/Tests/TatwoHostDaemonTests"
        ),
        .testTarget(
            name: "TatwoUltraworkCoreTests",
            dependencies: [
                "TatwoUltraworkCore",
                "TatwoUltraworkTestSupport",
                "TatwoDomainContracts",
                "TatwoWorkReceiptContracts",
                "tatwo-ar-race-helper"
            ],
            path: "Packages/TatwoUltraworkCore/Tests/TatwoUltraworkCoreTests"
        ),
        .testTarget(
            name: "TatwoUltraworkMacTests",
            dependencies: [
                "TatwoUltraworkMac",
                "TatwoUltraworkCore",
                "TatwoUltraworkTestSupport",
                "TatwoDomainContracts",
                "TatwoCEFBridge",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Apps/TatwoUltraworkMac/Tests/TatwoUltraworkMacTests",
            sources: macTestSources,
            resources: macTestResources,
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../../.."
                ])
            ]
        )
    ]
)
