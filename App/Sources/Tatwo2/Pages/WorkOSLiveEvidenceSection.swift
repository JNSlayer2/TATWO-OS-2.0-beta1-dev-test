// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/WorkOSLiveEvidenceSection.swift；改動 2 行（原因：加來源註記並移除舊 core import）
import SwiftUI

// Live 沙盒 run + GBrain 記憶可視化（使用者 goal#2-C：沙盒可視化；GBrain：OS 讀 GBrain 不融合）。
// 純讀 TatwoSandboxRunReader / TatwoGBrainReader；缺根/無權限優雅顯示狀態，不 crash。
// 視覺跟主題（GlassCard/液態玻璃 aurora、扁平牛皮紙 fable5）。
//
// OS root 注入（F7 graceful-empty）：
// 1. 環境變數 `TATWO_OS_ROOT`
// 2. App Support `os-root.local.json`（若存在）
// 3. 皆無 → section 顯示「未配置 OS root」，不 hardcode 本機絕對路徑
//
// `os-root.local.json` 格式（本機使用者狀態；App 不建立此檔）：
// {
//   "osRoot": "<absolute path>",
//   "sandboxRoot": "<optional absolute override>",
//   "gbrainRoot": "<optional absolute override>"
// }
// 未給 override 時：sandbox = <osRoot>/.tatwo-ultrawork；gbrain = <osRoot>/gbrain

struct WorkOSLiveEvidenceSection: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    private static let osRootEnvKey = "TATWO_OS_ROOT"
    private static let osRootLocalFileName = "os-root.local.json"

    @State private var runs: [TatwoSandboxRun] = []
    @State private var gbrain = TatwoGBrainListResult(entries: [], status: .rootMissing)
    @State private var loaded = false
    @State private var osRootConfigured = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if loaded && !osRootConfigured {
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader("Work OS live evidence", systemImage: "externaldrive",
                                      trailing: "未配置")
                        emptyRow("未配置 OS root")
                    }
                }
            } else {
                sandboxCard
                gbrainCard
            }
        }
        .onAppear(perform: loadIfNeeded)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let roots = Self.resolveLiveRoots() else {
            osRootConfigured = false
            runs = []
            gbrain = TatwoGBrainListResult(entries: [], status: .rootMissing)
            return
        }
        osRootConfigured = true
        runs = TatwoSandboxRunReader(rootURL: roots.sandboxRoot).listRuns()
        gbrain = TatwoGBrainReader(rootURL: roots.gbrainRoot).list()
    }

    // MARK: - Injectable OS root

    private struct LiveRoots {
        let sandboxRoot: URL
        let gbrainRoot: URL
    }

    private struct OsRootLocalFile: Decodable {
        var osRoot: String?
        var sandboxRoot: String?
        var gbrainRoot: String?
    }

    /// Resolution: `TATWO_OS_ROOT` → App Support `os-root.local.json` → nil (unconfigured).
    private static func resolveLiveRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> LiveRoots? {
        let fromEnv = nonempty(environment[osRootEnvKey])
        let fromFile = loadOsRootLocalFile(fileManager: fileManager)

        let osRootPath = fromEnv ?? fromFile.flatMap { nonempty($0.osRoot) }
        guard let osRootPath else { return nil }

        let osRoot = URL(fileURLWithPath: osRootPath, isDirectory: true)

        let sandboxPath = fromFile.flatMap { nonempty($0.sandboxRoot) }
        let gbrainPath = fromFile.flatMap { nonempty($0.gbrainRoot) }

        let sandboxRoot =
            sandboxPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? osRoot.appendingPathComponent(".tatwo-ultrawork", isDirectory: true)
        let gbrainRoot =
            gbrainPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? osRoot.appendingPathComponent("gbrain", isDirectory: true)

        return LiveRoots(sandboxRoot: sandboxRoot, gbrainRoot: gbrainRoot)
    }

    private static func loadOsRootLocalFile(
        fileManager: FileManager
    ) -> OsRootLocalFile? {
        let url = TatwoRuntimeLayout.applicationSupportRoot(fileManager: fileManager)
            .appendingPathComponent(osRootLocalFileName, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OsRootLocalFile.self, from: data)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    // MARK: 沙盒 runs

    private var sandboxCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("沙盒 Runs", systemImage: "shippingbox",
                              trailing: "\(runs.count) runs · \(Set(runs.map(\.sandboxType)).count) 類")
                if runs.isEmpty {
                    emptyRow("尚無沙盒 run（或路徑無權限）")
                } else {
                    ForEach(Array(runsByType.keys.sorted()), id: \.self) { type in
                        let items = runsByType[type] ?? []
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(type).font(.caption.weight(.bold)).frame(width: 132, alignment: .leading)
                                .lineLimit(1)
                            Text("\(items.count)").font(.caption2.weight(.black))
                                .foregroundStyle(LiquidGlassTokens.brandAccent)
                            Spacer()
                            // 最近 run 的收據狀態徽章
                            if let latest = items.max(by: { $0.modifiedAt < $1.modifiedAt }) {
                                receiptBadges(latest)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    private var runsByType: [String: [TatwoSandboxRun]] {
        Dictionary(grouping: runs, by: \.sandboxType)
    }

    private func receiptBadges(_ run: TatwoSandboxRun) -> some View {
        HStack(spacing: 4) {
            miniBadge("摘要", run.hasSummary)
            miniBadge("封存", run.hasSeal)
            miniBadge("評分", run.hasScoreReport)
        }
    }

    private func miniBadge(_ label: String, _ on: Bool) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6).frame(height: 18)
            .background((on ? Color.green : Color.secondary).opacity(on ? 0.16 : 0.08), in: Capsule())
            .foregroundStyle(on ? Color.green : Color.secondary)
    }

    // MARK: GBrain 記憶

    private var gbrainCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("GBrain 記憶中樞（OS 只讀）", systemImage: "brain",
                              trailing: gbrainStatusLabel)
                if gbrain.entries.isEmpty {
                    emptyRow(gbrainEmptyReason)
                } else {
                    ForEach(gbrain.entries.prefix(12)) { entry in
                        HStack(spacing: 8) {
                            Text(entry.layer.rawValue)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6).frame(height: 18)
                                .background(LiquidGlassTokens.brandAccent.opacity(0.14), in: Capsule())
                                .foregroundStyle(LiquidGlassTokens.brandAccent)
                            Text(entry.title.isEmpty ? entry.fileName : entry.title)
                                .font(.caption).lineLimit(1)
                            Spacer()
                            Text(byteLabel(entry.size)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    if gbrain.entries.count > 12 {
                        Text("…共 \(gbrain.entries.count) 筆").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var gbrainStatusLabel: String {
        switch gbrain.status {
        case .available: return "\(gbrain.entries.count) 筆 curated/truth"
        case .rootMissing: return "路徑不存在"
        case .permissionDenied: return "無權限"
        default: return "無法讀取"
        }
    }

    private var gbrainEmptyReason: String {
        switch gbrain.status {
        case .rootMissing: return "GBrain 路徑不存在（此機未掛載或路徑不同）"
        case .permissionDenied: return "無權限讀 GBrain（App 需外接卷存取權）"
        default: return "GBrain curated/truth 目前無條目"
        }
    }

    // MARK: 共用

    private func sectionHeader(_ title: String, systemImage: String, trailing: String) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage).font(.subheadline.weight(.black))
            Spacer()
            Text(trailing).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
    }

    private func byteLabel(_ bytes: Int64) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1fMB", Double(bytes) / 1_048_576) }
        if bytes >= 1024 { return "\(bytes / 1024)KB" }
        return "\(bytes)B"
    }
}
