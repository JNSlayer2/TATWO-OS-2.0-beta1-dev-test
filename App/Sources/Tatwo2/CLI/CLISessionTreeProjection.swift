// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/CLISessionTreeProjection.swift；改動 19 行（原因：加入來源標記；消除薄殼同名假資料與 Core 值型別歧義）
import Foundation

/// CLI 左列 session 樹的純投影層。
///
/// 段一「終端 Sessions」由 UI 直接收既有專案／session 清單。
/// 段二「Loops」：進行中 + 近 1h 完成／失敗；資料源＝同一份 dispatch registry
/// （chat / Ultrawork 派工寫入後，此處零設定自動出現）。
///
/// 不碰 Packages、不 stat /Volumes；裝置欄位若 Codable 解不到就標「本機」。

// MARK: - Row models

enum CLILoopTreeStatus: String, Equatable, Sendable {
    case queued
    case running
    case completed
    case verified
    case failed

    init(_ status: TatwoDispatchStatus) {
        switch status {
        case .queued: self = .queued
        case .running: self = .running
        case .completed: self = .completed
        case .verified: self = .verified
        case .failed: self = .failed
        }
    }

    /// Fallback when no remote five-state status is available.
    var label: String {
        switch self {
        case .queued: return "排隊"
        case .running: return "執行中"
        case .completed: return "完成"
        case .verified: return "已驗收"
        case .failed: return "失敗"
        }
    }

    /// Prefer remote-loop design labels (5.6-1) when `remoteStatus` is known.
    static func presentationLabel(
        dispatchStatus: TatwoDispatchStatus,
        remoteStatus: TatwoLoopJobStatusV1?
    ) -> String {
        if let remoteStatus {
            return remoteStatus.designSemanticLabel
        }
        return CLILoopTreeStatus(dispatchStatus).label
    }

    var isActive: Bool {
        self == .queued || self == .running
    }
}

/// 可選裝置欄位（另一 loop 可能加在 registry JSON；解不到視為本機）。
struct CLILoopDeviceFields: Equatable, Sendable {
    var originDeviceID: String?
    var targetDeviceID: String?

    static let empty = CLILoopDeviceFields(originDeviceID: nil, targetDeviceID: nil)

    var hasAnyDevice: Bool {
        let origin = originDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target = targetDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !origin.isEmpty || !target.isEmpty
    }
}

/// 左列 Loops 段的一列。
struct CLILoopTreeRow: Identifiable, Equatable, Sendable {
    let id: String
    let contractID: String
    let bindingID: String
    let identity: String
    let modelID: String
    let subtask: String
    let status: CLILoopTreeStatus
    let startedAt: Date
    let updatedAt: Date
    let goalID: String?
    let originDeviceID: String?
    let targetDeviceID: String?
    /// 可導出時顯示來源 thread 標籤（例如 thread 標題）；導不出為 nil。
    let sourceThreadLabel: String?
    /// Design 5.6-1 label when remoteStatus is present; else local dispatch label.
    let statusLabel: String

    var displayName: String {
        modelID.isEmpty ? bindingID : modelID
    }

    var isActive: Bool { status.isActive }

    /// 本機／遠端裝置標籤：解不到 device 欄位 →「本機」。
    var deviceLabel: String {
        let target = targetDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !target.isEmpty {
            return Self.shortDevice(target)
        }
        let origin = originDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !origin.isEmpty {
            return Self.shortDevice(origin)
        }
        return "本機"
    }

    var isRemoteDevice: Bool {
        let target = targetDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let origin = originDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !target.isEmpty || !origin.isEmpty
    }

    /// 跨裝置算力：target 端的 inbound 鏡像列，或 origin/target 分屬不同裝置的派工。
    /// 兩端同名（同機自派）不算遠端，避免本機 loops 被誤分到遠端區塊。
    var isRemoteCompute: Bool {
        if bindingID.hasPrefix("inbound-remote-loop-") { return true }
        let target = targetDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let origin = originDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !target.isEmpty, !origin.isEmpty else { return false }
        return target.caseInsensitiveCompare(origin) != .orderedSame
    }

    private static func shortDevice(_ raw: String) -> String {
        if raw.count <= 12 { return raw }
        return String(raw.prefix(8)) + "…"
    }
}

struct CLILoopTimelineEvent: Identifiable, Equatable, Sendable {
    let id: String
    let status: CLILoopTreeStatus
    let at: Date
    let detail: String
}

/// 點 loop 列後主區唯讀詳情。
struct CLILoopDetailSnapshot: Equatable, Sendable {
    let row: CLILoopTreeRow
    let timeline: [CLILoopTimelineEvent]
    /// 目前輸出／收據文字（從 dispatch 紀錄欄位組出，唯讀）。
    let outputText: String
    let canStop: Bool
}

// MARK: - Projection policy (pure)

enum CLILoopsTreePolicy {
    /// 最近完成／失敗保留視窗。
    static let recentCompletedWindow: TimeInterval = 60 * 60

    /// 從 dispatch runs 投影左列 Loops 段。
    /// - Parameters:
    ///   - deviceFieldsByRecordID: 從 raw JSON 抽出的裝置欄位（Codable 解不到則空）。
    ///   - sourceThreadByContractID: contract → thread 標題（chat 派工閉環標籤）。
    ///   - sourceThreadByGoalID: goal → thread 標題。
    static func project(
        from runs: [TatwoStoredDispatchRun],
        now: Date = Date(),
        deviceFieldsByRecordID: [String: CLILoopDeviceFields] = [:],
        sourceThreadByContractID: [String: String] = [:],
        sourceThreadByGoalID: [String: String] = [:]
    ) -> [CLILoopTreeRow] {
        var rows: [CLILoopTreeRow] = []

        for run in runs {
        var latest: [String: TatwoDispatchRecord] = [:]
            for record in run.records {
                if let existing = latest[record.bindingID], existing.updatedAt >= record.updatedAt {
                    continue
                }
                latest[record.bindingID] = record
            }

            for record in latest.values {
                let status = CLILoopTreeStatus(record.status)
                if status.isActive {
                    // 封存 run 殘留 running 不算進行中（與 TatwoLoopsActivityPolicy 一致）。
                    guard run.sealID == nil else { continue }
                    guard now.timeIntervalSince(record.updatedAt) <= TatwoLoopsActivityPolicy.staleCutoff
                    else { continue }
                } else {
                    // 近 1h 完成／失敗；封存與否都收。
                    guard now.timeIntervalSince(record.updatedAt) <= recentCompletedWindow else {
                        continue
                    }
                }

                let devices = deviceFieldsByRecordID[record.id] ?? .empty
                let sourceLabel = resolveSourceThreadLabel(
                    contractID: record.contractID,
                    goalID: record.goalID,
                    byContract: sourceThreadByContractID,
                    byGoal: sourceThreadByGoalID)
                let statusLabel = CLILoopTreeStatus.presentationLabel(
                    dispatchStatus: record.status,
                    remoteStatus: record.remoteStatus)

                rows.append(
                    CLILoopTreeRow(
                        id: record.id,
                        contractID: record.contractID,
                        bindingID: record.bindingID,
                        identity: record.identity.rawValue,
                        modelID: record.modelID,
                        subtask: record.subtask.trimmingCharacters(in: .whitespacesAndNewlines),
                        status: status,
                        startedAt: record.startedAt,
                        updatedAt: record.updatedAt,
                        goalID: record.goalID,
                        originDeviceID: devices.originDeviceID,
                        targetDeviceID: devices.targetDeviceID,
                        sourceThreadLabel: sourceLabel,
                        statusLabel: statusLabel))
            }
        }

        rows.sort { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive && !rhs.isActive }
            if lhs.status == .running && rhs.status == .queued { return true }
            if lhs.status == .queued && rhs.status == .running { return false }
            return lhs.updatedAt > rhs.updatedAt
        }
        return rows
    }

    /// chat 派工閉環：只要 registry 有紀錄就進樹，不需 CLI 專用設定。
    /// 此函式僅語意錨定＋測試入口，實作等於 `project`。
    static func projectChatDispatchedLoops(
        from runs: [TatwoStoredDispatchRun],
        now: Date = Date(),
        sourceThreadByContractID: [String: String] = [:],
        sourceThreadByGoalID: [String: String] = [:]
    ) -> [CLILoopTreeRow] {
        project(
            from: runs,
            now: now,
            sourceThreadByContractID: sourceThreadByContractID,
            sourceThreadByGoalID: sourceThreadByGoalID)
    }

    /// 從活動 fixture 列轉成樹列（export 路徑；可帶遠端裝置）。
    static func rows(fromActivityRows rows: [TatwoLoopsActivityRow]) -> [CLILoopTreeRow] {
        rows.map { row in
            let status: CLILoopTreeStatus = row.queued ? .queued : .running
            return CLILoopTreeRow(
                id: row.id,
                contractID: row.contractID,
                bindingID: row.bindingID,
                identity: row.identity,
                modelID: row.modelID,
                subtask: row.subtask,
                status: status,
                startedAt: row.startedAt,
                updatedAt: row.updatedAt,
                goalID: nil,
                originDeviceID: row.originDeviceID,
                targetDeviceID: row.targetDeviceID,
                sourceThreadLabel: nil,
                statusLabel: status.label)
        }
    }

    static func resolveSourceThreadLabel(
        contractID: String,
        goalID: String?,
        byContract: [String: String],
        byGoal: [String: String]
    ) -> String? {
        if let goalID, !goalID.isEmpty, let title = byGoal[goalID], !title.isEmpty {
            return title
        }
        if let title = byContract[contractID], !title.isEmpty {
            return title
        }
        return nil
    }
}

// MARK: - Detail reader (pure)

enum CLILoopDetailReader {
    /// 依 record id 綁定詳情：時間線＝同 binding 全部紀錄；輸出＝最新筆的 receipt／output／error。
    static func detail(
        forRecordID recordID: String,
        runs: [TatwoStoredDispatchRun],
        now: Date = Date(),
        deviceFieldsByRecordID: [String: CLILoopDeviceFields] = [:],
        sourceThreadByContractID: [String: String] = [:],
        sourceThreadByGoalID: [String: String] = [:]
    ) -> CLILoopDetailSnapshot? {
        let rows = CLILoopsTreePolicy.project(
            from: runs,
            now: now,
            deviceFieldsByRecordID: deviceFieldsByRecordID,
            sourceThreadByContractID: sourceThreadByContractID,
            sourceThreadByGoalID: sourceThreadByGoalID)

        // 詳情允許點進「樹上看得到」的列；若樹投影因窗口裁掉，仍嘗試從 raw 綁定。
        let row: CLILoopTreeRow
        if let existing = rows.first(where: { $0.id == recordID }) {
            row = existing
        } else if let rebuilt = rebuildRow(
            recordID: recordID,
            runs: runs,
            deviceFieldsByRecordID: deviceFieldsByRecordID,
            sourceThreadByContractID: sourceThreadByContractID,
            sourceThreadByGoalID: sourceThreadByGoalID)
        {
            row = rebuilt
        } else {
            return nil
        }

        guard let host = runs.first(where: { $0.records.contains(where: { $0.id == recordID }) })
        else { return nil }

        let bindingID = row.bindingID
        let bindingRecords = host.records
            .filter { $0.bindingID == bindingID }
            .sorted { $0.updatedAt < $1.updatedAt }

        let timeline: [CLILoopTimelineEvent] = bindingRecords.map { record in
            let status = CLILoopTreeStatus(record.status)
            var detail = CLILoopTreeStatus.presentationLabel(
                dispatchStatus: record.status,
                remoteStatus: record.remoteStatus)
            if let receipt = record.receiptID, !receipt.isEmpty {
                detail += " · receipt \(receipt)"
            }
            if let err = record.errorMessage, !err.isEmpty {
                detail += " · \(err)"
            }
            return CLILoopTimelineEvent(
                id: record.id,
                status: status,
                at: record.updatedAt,
                detail: detail)
        }

        let latest = bindingRecords.last
        let outputText = composeOutputText(latest)

        return CLILoopDetailSnapshot(
            row: row,
            timeline: timeline,
            outputText: outputText,
            canStop: row.isActive)
    }

    private static func rebuildRow(
        recordID: String,
        runs: [TatwoStoredDispatchRun],
        deviceFieldsByRecordID: [String: CLILoopDeviceFields],
        sourceThreadByContractID: [String: String],
        sourceThreadByGoalID: [String: String]
    ) -> CLILoopTreeRow? {
        for run in runs {
            guard let record = run.records.first(where: { $0.id == recordID }) else { continue }
            let devices = deviceFieldsByRecordID[record.id] ?? .empty
            let sourceLabel = CLILoopsTreePolicy.resolveSourceThreadLabel(
                contractID: record.contractID,
                goalID: record.goalID,
                byContract: sourceThreadByContractID,
                byGoal: sourceThreadByGoalID)
            return CLILoopTreeRow(
                id: record.id,
                contractID: record.contractID,
                bindingID: record.bindingID,
                identity: record.identity.rawValue,
                modelID: record.modelID,
                subtask: record.subtask.trimmingCharacters(in: .whitespacesAndNewlines),
                status: CLILoopTreeStatus(record.status),
                startedAt: record.startedAt,
                updatedAt: record.updatedAt,
                goalID: record.goalID,
                originDeviceID: devices.originDeviceID,
                targetDeviceID: devices.targetDeviceID,
                sourceThreadLabel: sourceLabel,
                statusLabel: CLILoopTreeStatus.presentationLabel(
                    dispatchStatus: record.status,
                    remoteStatus: record.remoteStatus))
        }
        return nil
    }

    private static func composeOutputText(_ record: TatwoDispatchRecord?) -> String {
        guard let record else { return "（尚無輸出）" }
        var parts: [String] = []
        if let outputRef = record.outputRef?.trimmingCharacters(in: .whitespacesAndNewlines),
           !outputRef.isEmpty
        {
            parts.append("outputRef: \(outputRef)")
        }
        if let receiptID = record.receiptID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !receiptID.isEmpty
        {
            parts.append("receiptID: \(receiptID)")
        }
        if let error = record.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty
        {
            parts.append("error: \(error)")
        }
        if let failure = record.failureReceipt {
            parts.append("failure: \(failure.failureClass.rawValue) — \(failure.operatorMessage)")
            if let code = failure.errorCode, !code.isEmpty {
                parts.append("errorCode: \(code)")
            }
        }
        if parts.isEmpty {
            return "（紀錄無 outputRef／receipt／error 文字）"
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Device field extraction (raw JSON, optional)

enum CLIDispatchDeviceFieldReader {
    /// 從 run 檔 JSON 抽出各 record 的 origin/target device（解不到就略過）。
    /// 只給 UI 投影用；不寫 store、不新增 /Volumes stat。
    static func fieldsByRecordID(in runJSON: Data) -> [String: CLILoopDeviceFields] {
        guard
            let root = try? JSONSerialization.jsonObject(with: runJSON) as? [String: Any],
            let records = root["records"] as? [[String: Any]]
        else { return [:] }

        var result: [String: CLILoopDeviceFields] = [:]
        for record in records {
            guard let id = record["id"] as? String, !id.isEmpty else { continue }
            let origin = nonEmptyString(record["originDeviceID"])
            let target = nonEmptyString(record["targetDeviceID"])
            if origin == nil && target == nil { continue }
            result[id] = CLILoopDeviceFields(originDeviceID: origin, targetDeviceID: target)
        }
        return result
    }

    /// 掃 registry 目錄下的 run 檔。目錄不存在 → 空。
    static func fieldsByRecordID(directoryURL: URL, fileManager: FileManager = .default)
        -> [String: CLILoopDeviceFields]
    {
        guard
            let files = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil),
            !files.isEmpty
        else { return [:] }

        var merged: [String: CLILoopDeviceFields] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            let partial = fieldsByRecordID(in: data)
            for (key, value) in partial {
                merged[key] = value
            }
        }
        return merged
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Live tree loader

/// 讀 registry 投影左列 Loops；export fixture 優先且不碰真實 store。
enum CLILoopsTreeLoader {
    static func loadLoopRows(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        sourceThreadByContractID: [String: String] = [:],
        sourceThreadByGoalID: [String: String] = [:]
    ) -> [CLILoopTreeRow] {
        if let fixture = TatwoLoopsActivityFixture.snapshot(
            kind: environment["TATWO_ULTRAWORK_EXPORT_LOOPS_FIXTURE"],
            now: now)
        {
            return CLILoopsTreePolicy.rows(fromActivityRows: fixture.rows)
        }

        let registry = TatwoDispatchRegistry.default(environment: environment)
        let runs = registry.allRuns()
        let devices = CLIDispatchDeviceFieldReader.fieldsByRecordID(directoryURL: registry.directoryURL)
        return CLILoopsTreePolicy.project(
            from: runs,
            now: now,
            deviceFieldsByRecordID: devices,
            sourceThreadByContractID: sourceThreadByContractID,
            sourceThreadByGoalID: sourceThreadByGoalID)
    }

    static func loadDetail(
        recordID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        sourceThreadByContractID: [String: String] = [:],
        sourceThreadByGoalID: [String: String] = [:]
    ) -> CLILoopDetailSnapshot? {
        if let fixture = TatwoLoopsActivityFixture.snapshot(
            kind: environment["TATWO_ULTRAWORK_EXPORT_LOOPS_FIXTURE"],
            now: now)
        {
            let rows = CLILoopsTreePolicy.rows(fromActivityRows: fixture.rows)
            guard let row = rows.first(where: { $0.id == recordID }) else { return nil }
            return CLILoopDetailSnapshot(
                row: row,
                timeline: [
                    CLILoopTimelineEvent(
                        id: row.id,
                        status: row.status,
                        at: row.updatedAt,
                        detail: row.statusLabel)
                ],
                outputText: row.subtask.isEmpty ? "（fixture 無收據本文）" : row.subtask,
                canStop: row.isActive)
        }

        let registry = TatwoDispatchRegistry.default(environment: environment)
        let runs = registry.allRuns()
        let devices = CLIDispatchDeviceFieldReader.fieldsByRecordID(directoryURL: registry.directoryURL)
        return CLILoopDetailReader.detail(
            forRecordID: recordID,
            runs: runs,
            now: now,
            deviceFieldsByRecordID: devices,
            sourceThreadByContractID: sourceThreadByContractID,
            sourceThreadByGoalID: sourceThreadByGoalID)
    }
}
