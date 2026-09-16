// engine-login 房間：集中 Tatwo2 內建引擎的獨立登入根與二進位路徑；合流時以 engine-bundle 房間為準。
import Foundation

struct EnginePaths: Sendable {
    let appSupportRoot: URL
    let enginesRoot: URL
    let codexHome: URL
    let claudeConfigDirectory: URL
    let grokHome: URL
    let runtimeBinDirectory: URL
    let codexExecutable: URL
    let claudeExecutable: URL
    let grokExecutable: URL
    let userHome: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resourceRoot: URL? = nil
    ) {
        let fileManager = FileManager.default
        let liveRoot = environment["TATWO2_LIVE_ROOT"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        }
        let defaultAppSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("tatwo2", isDirectory: true)
        let supportRoot = environment["TATWO2_ENGINES_ROOT"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        }

        if let supportRoot {
            self.appSupportRoot = supportRoot.deletingLastPathComponent()
            self.enginesRoot = supportRoot
        } else {
            self.appSupportRoot = liveRoot?.deletingLastPathComponent() ?? defaultAppSupport
            self.enginesRoot = self.appSupportRoot.appendingPathComponent(
                "engines",
                isDirectory: true
            )
        }

        self.codexHome = enginesRoot.appendingPathComponent("codex", isDirectory: true)
        self.claudeConfigDirectory = enginesRoot.appendingPathComponent(
            "claude",
            isDirectory: true
        )
        self.grokHome = enginesRoot.appendingPathComponent("grok", isDirectory: true)

        let resources = resourceRoot
            ?? environment["TATWO2_RESOURCES_ROOT"].flatMap {
                $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
            }
            ?? Bundle.main.resourceURL
            ?? TatwoResources.resourceURL
            ?? Bundle.main.bundleURL
        self.runtimeBinDirectory = resources.appendingPathComponent(
            "runtime/bin",
            isDirectory: true
        )
        self.codexExecutable = runtimeBinDirectory.appendingPathComponent("codex")
        self.grokExecutable = runtimeBinDirectory.appendingPathComponent("grok")
        self.claudeExecutable = resources
            .appendingPathComponent("claude-sidecar", isDirectory: true)
            .appendingPathComponent(
                "node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude"
            )
        self.userHome = environment["HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        } ?? fileManager.homeDirectoryForCurrentUser
    }

    var codexAuth: URL {
        codexHome.appendingPathComponent("auth.json")
    }

    var claudeAccountFile: URL {
        claudeConfigDirectory.appendingPathComponent(".claude.json")
    }

    var fallbackClaudeAccountFile: URL {
        userHome.appendingPathComponent(".claude.json")
    }

    var grokAuth: URL {
        grokHome
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    func createPrivateDirectories() {
        for directory in [enginesRoot, codexHome, claudeConfigDirectory, grokHome] {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
    }
}
