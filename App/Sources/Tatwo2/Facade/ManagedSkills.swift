import Foundation

/// W96：技能隨 App 出貨。公開版 App 也要有 `/tatwo-ultrawork`，
/// 所以 `skills/tatwo-ultrawork/{SKILL.md,agents/}` 打進 App Resources，
/// 首次啟動與每次更新以受管方式種到 `Application Support/tatwo2/skills/tatwo-ultrawork/`
/// （＝ PluginsSource 掃描的第一個技能根）。`references/` 是私人封存，不出貨也不種。
enum ManagedSkills {
    static let skillID = "tatwo-ultrawork"

    /// 一個出貨檔：種到 `skills/<skillID>/<relativePath>`；
    /// bundle 內以 SwiftPM `.copy` 的結果（檔名／子目錄）取用。
    struct BundledFile: Equatable {
        let relativePath: String
        let resource: String
        let ext: String
        let subdirectory: String?
    }

    static let files: [BundledFile] = [
        .init(relativePath: "SKILL.md", resource: "SKILL", ext: "md", subdirectory: nil),
        .init(relativePath: "agents/openai.yaml", resource: "openai", ext: "yaml", subdirectory: "agents"),
    ]

    enum Outcome: Equatable {
        case installed, updated, unchanged, keptUserEdited, failed(String)

        var logMessage: String {
            switch self {
            case .installed: return "installed"
            case .updated: return "updated"
            case .unchanged: return "unchanged"
            case .keptUserEdited: return "keptUserEdited"
            case .failed(let reason): return "failed \(reason)"
            }
        }
    }

    /// 設定 › Plugin 那一列要顯示的來源。
    enum Source: Equatable {
        case managed, userEdited, missing

        var label: String {
            switch self {
            case .managed: return "App 內建（受管）"
            case .userEdited: return "已手改（保留）"
            case .missing: return "App 內建（尚未種入）"
            }
        }
    }

    /// 與 PluginsSource 掃描的第一個根同一條路徑；HOME 被隔離時（乾淨安裝閘門）自然跟著隔離。
    static func defaultRoot() -> URL {
        URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/tatwo2/skills",
            isDirectory: true)
    }

    static func skillDirectory(root: URL = defaultRoot()) -> URL {
        root.appendingPathComponent(skillID, isDirectory: true)
    }

    static func manifestURL(root: URL = defaultRoot()) -> URL {
        skillDirectory(root: root).appendingPathComponent("SKILL.md")
    }

    static func bundledURL(for file: BundledFile) -> URL? {
        TatwoResources.url(forResource: file.resource, withExtension: file.ext,
                           subdirectory: file.subdirectory)
    }

    /// 啟動時種檔。`bundle` 只給測試用（一個與出貨相同版面的目錄）；
    /// 生產路徑一律讀 App 自己的 Resources。
    @discardableResult
    static func applyOnLaunch(root: URL = defaultRoot(), bundle: URL? = nil) -> [String: Outcome] {
        var outcomes: [String: Outcome] = [:]
        for file in files { outcomes[file.relativePath] = apply(file, root: root, bundle: bundle) }
        return outcomes
    }

    /// 一行摘要，給啟動日誌用（不含使用者路徑）。
    static func logLine(_ outcomes: [String: Outcome]) -> String {
        outcomes.keys.sorted()
            .map { "\($0)=\(outcomes[$0]?.logMessage ?? "missing")" }
            .joined(separator: " ")
    }

    static func source(root: URL = defaultRoot()) -> Source {
        let runtime = manifestURL(root: root)
        guard let bytes = try? Data(contentsOf: runtime) else { return .missing }
        let installed = ManagedFile.trimmedText(at: ManagedFile.markerURL(in: runtime.deletingLastPathComponent(), stem: "SKILL"))
        return installed == ManagedFile.sha256(bytes) ? .managed : .userEdited
    }

    /// 設定 › Plugin：這一列是不是 App 內建的受管技能；不是就回 nil，不動其他技能的顯示。
    static func sourceLabel(forSkillManifestPath path: String, root: URL = defaultRoot()) -> String? {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        guard candidate == manifestURL(root: root).standardizedFileURL.path else { return nil }
        return source(root: root).label
    }

    private static func apply(_ file: BundledFile, root: URL, bundle: URL?) -> Outcome {
        let source = bundle.map { $0.appendingPathComponent(file.relativePath) } ?? bundledURL(for: file)
        guard let source, let content = try? Data(contentsOf: source) else { return .failed("bundle_missing") }
        let runtime = skillDirectory(root: root).appendingPathComponent(file.relativePath)
        let directory = runtime.deletingLastPathComponent()
        let stem = runtime.deletingPathExtension().lastPathComponent
        let marker = ManagedFile.markerURL(in: directory, stem: stem)
        let fm = FileManager.default
        let digest = ManagedFile.sha256(content)
        do {
            if !fm.fileExists(atPath: runtime.path) {
                // 斷掉的 symlink 也算「使用者放了東西」：不覆蓋。
                guard (try? fm.destinationOfSymbolicLink(atPath: runtime.path)) == nil else {
                    return .failed("runtime_symlink_unreadable")
                }
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                try ManagedFile.writeManaged(content, digest: digest, runtime: runtime, marker: marker)
                try ManagedFile.clearNotice(at: ManagedFile.noticeURL(in: directory, stem: stem))
                return .installed
            }
            let current = ManagedFile.sha256(try Data(contentsOf: runtime))
            // 內容剛好相同不等於同意接管一份沒有標記的檔案，但也沒有東西要做。
            if current == digest {
                try ManagedFile.clearNotice(at: ManagedFile.noticeURL(in: directory, stem: stem))
                return .unchanged
            }
            // 只有「上次種下的雜湊」完全相符才自動更新；缺標記／壞標記一律保留。
            guard ManagedFile.trimmedText(at: marker) == current else {
                try Data("技能 \(skillID)／\(file.relativePath) 已手改；已保留自訂檔案，請到設定 › Plugin 檢視。\n".utf8)
                    .write(to: ManagedFile.noticeURL(in: directory, stem: stem), options: .atomic)
                return .keptUserEdited
            }
            try ManagedFile.writeManaged(content, digest: digest, runtime: runtime, marker: marker)
            try ManagedFile.clearNotice(at: ManagedFile.noticeURL(in: directory, stem: stem))
            return .updated
        } catch {
            let error = error as NSError
            return .failed("\(error.domain):\(error.code)")
        }
    }
}
