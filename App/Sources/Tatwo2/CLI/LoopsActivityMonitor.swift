// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/LoopsActivityMonitor.swift；改動 5 行（原因：加入來源標記；消除薄殼同名假資料與 Core 值型別歧義）
import Combine
import Foundation

/// Loops 進行中判定的**單一真相源**（process-wide）。
///
/// 需求：CLI 分頁的進行中列、左頁標題呼吸光暈、以及「中斷 loops 前二次確認」三處，
/// 對「現在到底有沒有 loops 在動」必須給同一個答案。任何一處自己數一套，就會出現
/// 「畫面說在跑但關窗不攔」這種互相打架的狀態。
///
/// 真值＝Work OS dispatch registry（磁碟上的 run 檔）；Wave1 後取代 archived WorkingPage 燈號源
/// `TatwoDispatchRegistry.default()`；不另造第二套事件系統。
/// 目錄由 `TatwoGoalRunStore` 的 env cascade 解析（state dir / app support），
/// 不新增任何對外接卷的 stat。

/// 一列「正在動的代理」。UI 只吃這個扁平列，不直接碰 registry 型別。
struct TatwoLoopsActivityRow: Identifiable, Equatable {
    let id: String
    let contractID: String
    let bindingID: String
    let identity: String
    let modelID: String
    let subtask: String
    let queued: Bool
    let startedAt: Date
    let updatedAt: Date
    /// 可選裝置欄位（另一 loop 可能寫入 registry；fixture 可合成遠端列）。
    /// Codable／registry 解不到時維持 nil → 顯示「本機」。
    let originDeviceID: String?
    let targetDeviceID: String?

    init(
        id: String,
        contractID: String,
        bindingID: String,
        identity: String,
        modelID: String,
        subtask: String,
        queued: Bool,
        startedAt: Date,
        updatedAt: Date,
        originDeviceID: String? = nil,
        targetDeviceID: String? = nil
    ) {
        self.id = id
        self.contractID = contractID
        self.bindingID = bindingID
        self.identity = identity
        self.modelID = modelID
        self.subtask = subtask
        self.queued = queued
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.originDeviceID = originDeviceID
        self.targetDeviceID = targetDeviceID
    }

    /// 顯示名：優先 modelID，退回 bindingID（和 WorkingLightRow 同一套退場順序）。
    var displayName: String {
        modelID.isEmpty ? bindingID : modelID
    }

    var statusLabel: String {
        queued ? "排隊" : "執行中"
    }

    var subActivityInput: TatwoLoopsSubActivityInput {
        TatwoLoopsSubActivityInput(
            id: id,
            contractID: contractID,
            identity: identity,
            modelName: displayName,
            subtask: subtask,
            queued: queued,
            startedAt: startedAt)
    }
}

/// 某一瞬間的 loops 活動快照。`isActive` 是三處共用的那個布林。
struct TatwoLoopsActivitySnapshot: Equatable {
    let rows: [TatwoLoopsActivityRow]
    let capturedAt: Date

    static let empty = TatwoLoopsActivitySnapshot(rows: [], capturedAt: .distantPast)

    var isActive: Bool { !rows.isEmpty }
    var activeCount: Int { rows.count }
    var runningCount: Int { rows.filter { !$0.queued }.count }
    var queuedCount: Int { rows.filter(\.queued).count }
}

/// 純函式判定層：吃 run 陣列吐快照，不做 I/O，可完整單元測試。
enum TatwoLoopsActivityPolicy {
    /// 孤兒保護：`updatedAt` 超過這個時距的 queued/running 記錄視為已死，不再算「進行中」。
    ///
    /// 為什麼要有：dispatch 記錄只在狀態轉換時更新 `updatedAt`，若某次派工的行程被 kill，
    /// 記錄會永遠停在 running。沒有這道 cutoff，之後每次關 app 都會被一筆殭屍記錄攔下來。
    /// 取 6 小時是刻意寬鬆——寧可多攔一次（使用者按「仍要結束」即可），也不要漏攔真在跑的長任務。
    static let staleCutoff: TimeInterval = 6 * 60 * 60

    static func snapshot(
        from runs: [TatwoStoredDispatchRun],
        now: Date = Date()
    ) -> TatwoLoopsActivitySnapshot {
        var rows: [TatwoLoopsActivityRow] = []
        for run in runs {
            // 已封存（sealed）的 run 代表這輪派工已結案，殘留的 running 記錄不再代表活動。
            guard run.sealID == nil else { continue }

            // 每個 (contract, binding) 只留最新一筆——與 archived WorkingPage 同一套收斂規則。
            // 先收斂再過濾：若某代理最新狀態已 completed，就算它更早有 running 記錄也不算在動。
        var latest: [String: TatwoDispatchRecord] = [:]
            for record in run.records {
                if let existing = latest[record.bindingID], existing.updatedAt >= record.updatedAt {
                    continue
                }
                latest[record.bindingID] = record
            }

            for record in latest.values {
                guard record.status == .queued || record.status == .running else { continue }
                guard now.timeIntervalSince(record.updatedAt) <= staleCutoff else { continue }
                rows.append(
                    TatwoLoopsActivityRow(
                        id: record.id,
                        contractID: record.contractID,
                        bindingID: record.bindingID,
                        identity: record.identity.rawValue,
                        modelID: record.modelID,
                        subtask: record.subtask.trimmingCharacters(in: .whitespacesAndNewlines),
                        queued: record.status == .queued,
                        startedAt: record.startedAt,
                        updatedAt: record.updatedAt))
            }
        }

        // running 排在 queued 前，同組再依最近更新排序（和 loopsLiveRows 的排法一致）。
        rows.sort { lhs, rhs in
            if lhs.queued != rhs.queued { return !lhs.queued }
            return lhs.updatedAt > rhs.updatedAt
        }
        return TatwoLoopsActivitySnapshot(rows: rows, capturedAt: now)
    }

    static func subActivityPresentation(
        rows: [TatwoLoopsActivityRow],
        currentContractID: String,
        phase: TatwoLoopsContractActivityPhase,
        now: Date
    ) -> TatwoLoopsSubActivityPresentation {
        TatwoLoopsSubActivityPresenter.present(
            rows: rows.map(\.subActivityInput),
            currentContractID: currentContractID,
            phase: phase,
            now: now)
    }
}

/// 快照匯出用的假 loops 活動。
///
/// 只給 export／測試路徑：`TATWO_ULTRAWORK_EXPORT_LOOPS_FIXTURE` 沒設就完全不生效，
/// 真實執行零行為差異。
///
/// **它是純記憶體合成，不讀也不寫 dispatch registry／goal store。**
/// （2026-07-13 教訓：CHAT_FIXTURE 未隔離 store 路徑覆蓋了真 threads。
/// 這裡從根上避免同類事故——fixture 路徑根本不碰任何 store。）
enum TatwoLoopsActivityFixture {
    /// 遠端 fixture 列的固定 targetDeviceID（僅 export／測試路徑）。
    static let fixtureRemoteTargetDeviceID = "fixture-remote-macbook"

    /// `kind`：`"1"` → 預設 2 running + 1 queued + 1 遠端 running；純數字 N → N 筆 running；其餘 → 不啟用。
    static func snapshot(kind: String?, now: Date = Date()) -> TatwoLoopsActivitySnapshot? {
        guard let kind, !kind.isEmpty else { return nil }

        let running: Int
        let queued: Int
        let includeRemoteDeviceRow: Bool
        if kind == "1" {
            // 本機 2 running + 1 queued，再加一筆帶 targetDevice 的遠端列（僅 fixture）。
            running = 2
            queued = 1
            includeRemoteDeviceRow = true
        } else if let count = Int(kind), count > 0 {
            running = count
            queued = 0
            includeRemoteDeviceRow = false
        } else {
            return nil
        }

        let models = ["gpt-5.6-sol", "claude-fable-5", "gpt-5.6-terra", "grok-4"]
        let subtasks = [
            "接線 CLI 分頁 PTY 終端",
            "盤點 LoopsSessionRail UI 區塊",
            "交叉驗證測試涵蓋",
            "查證關窗中斷鏈路"
        ]
        var rows: [TatwoLoopsActivityRow] = []
        for index in 0..<(running + queued) {
            let isQueued = index >= running
            rows.append(
                TatwoLoopsActivityRow(
                    id: "fixture-\(index)",
                    contractID: "contract-fixture",
                    bindingID: "binding-\(index)",
                    identity: isQueued ? "verifier" : "sub",
                    modelID: models[index % models.count],
                    subtask: subtasks[index % subtasks.count],
                    queued: isQueued,
                    startedAt: now.addingTimeInterval(-Double(180 + index * 90)),
                    updatedAt: now.addingTimeInterval(-Double(10 + index * 5))))
        }
        if includeRemoteDeviceRow {
            rows.append(
                TatwoLoopsActivityRow(
                    id: "fixture-remote",
                    contractID: "contract-fixture",
                    bindingID: "binding-remote",
                    identity: "sub",
                    modelID: "grok-4",
                    subtask: "遠端 sandbox 派工（fixture）",
                    queued: false,
                    startedAt: now.addingTimeInterval(-240),
                    updatedAt: now.addingTimeInterval(-15),
                    originDeviceID: "fixture-origin-mini",
                    targetDeviceID: fixtureRemoteTargetDeviceID))
        }
        return TatwoLoopsActivitySnapshot(rows: rows, capturedAt: now)
    }
}

/// 在背景輪詢 registry 並發布快照給 UI；AppKit termination gate 只讀已發布快照，
/// 絕不在主執行緒同步碰磁碟。
@MainActor
final class TatwoLoopsActivityMonitor: ObservableObject {
    static let shared = TatwoLoopsActivityMonitor()

    @Published private(set) var snapshot: TatwoLoopsActivitySnapshot = .empty

    /// 與 archived WorkingPage 燈號同節奏（5s）；CLI 列只是狀態列，不需要更密。
    private let interval: TimeInterval = 5
    private var timer: Timer?
    private var subscriberCount = 0
    private let pollCache = LoopsActivityPollCache()

    private init() {}

    /// AppKit termination callback 專用：只讀 process-local 已發布快照。
    ///
    /// `publishedSnapshot` 是測試 seam；production 留 nil 就讀 singleton 的
    /// `@Published snapshot`。fixture 仍優先，讓 export 行為保持完全決定性。
    /// 這條路徑不得加入 registry、FileManager、Data 或 URL resource I/O。
    static func terminationSnapshot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        publishedSnapshot: TatwoLoopsActivitySnapshot? = nil
    ) -> TatwoLoopsActivitySnapshot {
        if let fixture = TatwoLoopsActivityFixture.snapshot(
            kind: environment["TATWO_ULTRAWORK_EXPORT_LOOPS_FIXTURE"])
        {
            return fixture
        }
        return publishedSnapshot ?? shared.snapshot
    }

    /// 明確要求即時 registry 真值的非 UI probe。
    ///
    /// 這會同步讀磁碟；不得從 AppKit/SwiftUI main-thread callback 呼叫。
    nonisolated static func loopsInProgressNow(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TatwoLoopsActivitySnapshot {
        // 匯出／測試 fixture 優先，且直接 return——不落到下面的 registry 讀取，
        // 確保 fixture 路徑完全不接觸真實 store。
        if let fixture = TatwoLoopsActivityFixture.snapshot(
            kind: environment["TATWO_ULTRAWORK_EXPORT_LOOPS_FIXTURE"]) {
            return fixture
        }
        return TatwoLoopsActivityPolicy.snapshot(
            from: TatwoDispatchRegistry.default(environment: environment).allRuns())
    }

    /// UI 出現時掛載輪詢；用計數避免多個視圖各開一顆 timer。
    func attach() {
        subscriberCount += 1
        refresh()
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.timer = timer
    }

    func detach() {
        subscriberCount = max(0, subscriberCount - 1)
        guard subscriberCount == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let environment = ProcessInfo.processInfo.environment
        let cache = pollCache
        cache.queue.async { [weak self] in
            let next = Self.loadPolledSnapshot(cache: cache, environment: environment)
            Task { @MainActor in
                guard let self else { return }
                // 只在內容真的變了才發布，避免每 5 秒無謂觸發 SwiftUI 重繪。
                guard next.rows != self.snapshot.rows else { return }
                self.snapshot = next
            }
        }
    }

    /// Timer 路徑：目錄 stamp 沒變就跳過 Data+JSONDecode；終止閘門只讀發布後的 snapshot。
    nonisolated private static func loadPolledSnapshot(
        cache: LoopsActivityPollCache,
        environment: [String: String]
    ) -> TatwoLoopsActivitySnapshot {
        if let fixture = TatwoLoopsActivityFixture.snapshot(
            kind: environment["TATWO_ULTRAWORK_EXPORT_LOOPS_FIXTURE"])
        {
            return fixture
        }
        let registry = TatwoDispatchRegistry.default(environment: environment)
        let stamp = directoryStamp(for: registry)
        if stamp == cache.stamp, let runs = cache.runs {
            return TatwoLoopsActivityPolicy.snapshot(from: runs)
        }
        let runs = registry.allRuns()
        cache.stamp = stamp
        cache.runs = runs
        return TatwoLoopsActivityPolicy.snapshot(from: runs)
    }

    nonisolated private static func directoryStamp(
        for registry: TatwoDispatchRegistry
    ) -> DispatchesDirectoryStamp {
        let dir = registry.directoryURL.appendingPathComponent("dispatches", isDirectory: true)
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles])) ?? []
        let jsonFiles = files.filter { $0.pathExtension == "json" }
        var maxContentMTime: TimeInterval = 0
        var totalSize = 0
        for url in jsonFiles {
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey])
            if let timestamp = values?.contentModificationDate?.timeIntervalSince1970,
               timestamp > maxContentMTime
            {
                maxContentMTime = timestamp
            }
            totalSize += values?.fileSize ?? 0
        }
        return DispatchesDirectoryStamp(
            fileCount: jsonFiles.count,
            maxContentMTime: maxContentMTime,
            totalSize: totalSize)
    }
}

private struct DispatchesDirectoryStamp: Equatable, Sendable {
    var fileCount: Int
    var maxContentMTime: TimeInterval
    var totalSize: Int
}

private final class LoopsActivityPollCache: @unchecked Sendable {
    let queue = DispatchQueue(label: "tatwo.loops.activity.io", qos: .utility)
    var stamp: DispatchesDirectoryStamp?
    var runs: [TatwoStoredDispatchRun]?
}
