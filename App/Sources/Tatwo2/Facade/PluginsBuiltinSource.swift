import Foundation
import ApplicationServices
import CoreGraphics

struct BuiltinPluginRuntimeSnapshot: Sendable {
    var accessibility = false
    var screenRecording = false
    var computerEnabled = true
    var webToolCount: Int? = nil
    var osListening = false
    var browserListening = false

    @MainActor static func current() -> Self {
        .init(accessibility: AXIsProcessTrusted(), screenRecording: CGPreflightScreenCaptureAccess(),
              computerEnabled: ComputerUseSettings.shared.enabled,
              webToolCount: TatwoWebMCPRuntime.shared.registeredToolCount,
              osListening: OSAgentBridge.shared.isListening, browserListening: BrowserAgentBridge.shared.isListening)
    }
}

extension PluginsSource {
    static func builtinEntries(environment: [String: String] = ProcessInfo.processInfo.environment,
                               runtime: BuiltinPluginRuntimeSnapshot? = nil) -> [PluginRegistryEntry] {
        guard NativeStagingIsolation.validationError(environment) == nil else { return [] }
        let paths = EnginePaths(environment: environment)
        let resources = paths.runtimeBinDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let now = Date()
        func serverSource(_ name: String) -> String? {
            let bundled = resources.appendingPathComponent("\(name)/server.mjs")
            if let text = try? String(contentsOf: bundled, encoding: .utf8) { return text }
            guard !NativeStagingIsolation.isEnabled(environment) else { return nil }
            // Same installed sidecar root as the engine; do not count an unrelated checkout.
            let adjacent = URL(fileURLWithPath: ClaudeSidecar.scriptPath(for: .claude))
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("\(name)/server.mjs")
            return try? String(contentsOf: adjacent, encoding: .utf8)
        }
        let osNames = serverSource("os-mcp").map(PluginProbe.toolNames)
        let browserNames = serverSource("browser-mcp").map(PluginProbe.toolNames)
        let auditAllowed = !NativeStagingIsolation.isEnabled(environment) && !isExport(environment)
        let webLast = auditAllowed ? BrowserDiagnosticsAudit.readTail(at: TatwoWebMCPRuntime.auditURL).lastCalledAt : nil
        let loginLast = auditAllowed ? BrowserDiagnosticsAudit.readTail(at: BrowserDiagnosticsAudit.aiLoginURL).lastCalledAt : nil
        func bridge(_ listening: Bool?, names: [String]?) -> PluginLivenessResult {
            guard names?.isEmpty == false else {
                return .init(state: .unreachable, detail: "內建工具定義不可用", probedAt: now)
            }
            guard let listening else { return .init(state: .unknown, detail: "尚未讀取本機橋接狀態") }
            return .init(state: listening ? .ready : .unreachable,
                         detail: listening ? "本機橋接已啟動" : "本機橋接未啟動", probedAt: now)
        }
        let computer: PluginLivenessResult
        if let runtime {
            if !runtime.computerEnabled { computer = .init(state: .disabled, probedAt: now) }
            else if !runtime.accessibility { computer = .init(state: .unreachable, detail: "需要輔助使用權限", probedAt: now) }
            else if !runtime.screenRecording { computer = .init(state: .unreachable, detail: "需要螢幕錄製權限", probedAt: now) }
            else { computer = .init(state: .ready, detail: "輔助使用與螢幕錄製已授權", probedAt: now) }
        } else { computer = .init(state: .unknown) }
        let web = PluginLivenessResult(state: (runtime?.webToolCount ?? 0) > 0 ? .ready : .unknown,
            detail: (runtime?.webToolCount ?? 0) > 0 ? "分頁已登記工具" : "目前沒有網頁登記工具", probedAt: now)
        func entry(_ id: String, _ name: String, _ purpose: String, _ state: PluginLivenessResult,
                   _ count: Int?, _ last: Date? = nil) -> PluginRegistryEntry {
            .init(id: "builtin:\(id)", name: name, kind: .builtin, purpose: purpose, path: nil,
                  trigger: "由 OS 提供；個別操作仍依權限與分頁狀態。",
                  safetyLevel: .medium, installState: .installed, smokeCommand: nil, publicInstallHint: "隨 OS 提供",
                  liveness: state, toolCount: count, lastCalledAt: last, availableTo: ["Codex", "Claude", "Grok"])
        }
        return [
            entry("os-mcp", "os-mcp", "CLI 分頁、背景工作、派工房間、Bot 記憶、iPad、裝置",
                  bridge(runtime?.osListening, names: osNames), osNames?.count),
            entry("browser-mcp", "browser-mcp", "開網頁、讀內容、點擊打字、AI 帳號登入、網頁工具",
                  bridge(runtime?.browserListening, names: browserNames), browserNames?.count,
                  [webLast, loginLast].compactMap { $0 }.max()),
            entry("computer-use", "Computer Use", "操作整台電腦的畫面與鍵鼠", computer,
                  osNames?.filter { $0.hasPrefix("computer_") }.count),
            entry("webmcp", "WebMCP 頁面工具", "網頁登記給 AI 的工具", web, runtime?.webToolCount, webLast),
        ]
    }
}
