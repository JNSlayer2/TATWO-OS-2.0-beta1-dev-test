// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/PluginsPage.swift；改動 2 行（原因：run A plugins 照搬；移除舊 core import，資料由同名 Facade 提供）
import SwiftUI
import AppKit

struct PluginsPage: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let entries: [PluginRegistryEntry]
    let environment: [TatwoEnvironmentComponent]
    let skillsDirectoryCatalog: TatwoSkillsDirectoryCatalog
    let skilletRepositoryStore: TatwoSkilletRepositoryStore
    let onRegister: (RegistryKind, String, String, String?) throws -> Void
    let onRemove: (PluginRegistryEntry) throws -> Void
    let onSyncClaude: () async throws -> TatwoClaudeMCPSyncReceiptV1
    var pocketThreadID: UUID? = nil
    var scrollsContent = false

    @State private var showingAddForm = false
    @State private var draftKind = RegistryKind.skill
    @State private var draftName = ""
    @State private var draftPath = ""
    @State private var draftPurpose = ""
    @State private var statusMessage = "staging registry"
    @State private var pendingRemoval: PluginRegistryEntry?
    @State private var isSyncingClaude = false
    @State private var refreshedMCPEntries: [PluginRegistryEntry]?
    @State private var isProbing = false

    @State private var canonicalSkills: [TatwoSkillsDirectoryEntryV1] = []
    @State private var canonicalRootAvailable = true
    @State private var canonicalReadFailure: ExternalVolumeFailure?
    @State private var hasScannedCanonical = false
    @State private var isScanningCanonical = false
    @State private var expandedCanonicalIDs: Set<String> = []
    @State private var canonicalSummaries: [String: SkilletRepositorySummary] = [:]
    @State private var canonicalDetailCache: [String: SkilletRepositoryDetail] = [:]
    @State private var canonicalDetailTabs: [String: SkilletDetailTab] = [:]
    @State private var snapshottingCanonicalIDs: Set<String> = []
    @State private var selectedMergeRevisionByProposal: [String: String] = [:]
    @State private var pendingMergeDecision: SkilletMergeDecisionRequest?
    @State private var decidingMergeProposalIDs: Set<String> = []

    private var canRegister: Bool {
        !draftPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !draftPurpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isSnapshotExport: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil
            || environment["TATWO_ULTRAWORK_EXPORT_PANEL_SNAPSHOT"] != nil
    }

    private var snapshotDetailTab: SkilletDetailTab? {
        guard isSnapshotExport,
              ProcessInfo.processInfo.environment[
                "TATWO_ULTRAWORK_EXPORT_EXPAND_SKILLET"
              ] == "1"
        else {
            return nil
        }
        switch ProcessInfo.processInfo.environment[
            "TATWO_ULTRAWORK_EXPORT_SKILLET_TAB"
        ]?.lowercased() {
        case "history": return .history
        case "merges": return .merges
        case "devices": return .devices
        case "receipts": return .receipts
        default: return .files
        }
    }

    private var partition: TatwoPluginRegistryPartition {
        TatwoPluginRegistryPartition.make(entries)
    }

    @AppStorage("tatwo.plugins.selectedTab") private var selectedTab = "skills"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            topBar
            if showingAddForm && selectedTab != "pocket" { addForm }
            if statusMessage != "staging registry" && selectedTab != "pocket" {
                Text(statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
            if selectedTab == "pocket" {
                PocketSettingsView(threadID: pocketThreadID)
            } else {
                if scrollsContent {
                    ScrollView {
                        registryContent
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    registryContent
                }
            }
        }
        .alert(
            "移除 registry 項目？",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingRemoval = nil }
            Button("移除", role: .destructive) {
                guard let entry = pendingRemoval else { return }
                remove(entry)
            }
        } message: {
            Text("移除後，Scenario 外掛分頁與工作筐 chips 會同步移除。")
        }
        .confirmationDialog(
            "確認 Skillet merge 決策？",
            isPresented: Binding(
                get: { pendingMergeDecision != nil },
                set: { if !$0 { pendingMergeDecision = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let request = pendingMergeDecision {
                Button(
                    request.kind == .approve ? "確認批准" : "確認拒絕",
                    role: request.kind == .reject ? .destructive : nil
                ) {
                    performMergeDecision(request)
                }
                Button("取消", role: .cancel) {
                    pendingMergeDecision = nil
                }
            }
        } message: {
            if let request = pendingMergeDecision {
                Text(
                    request.kind == .approve
                        ? "批准只會推進 Skillet repository canonical metadata；"
                            + "執行前後會重新 hash runtime，若 runtime 有任何變動即 fail-closed。"
                        : "拒絕會保留 incoming branch 與 conflict artifacts，"
                            + "並寫入可回查 decision receipt。"
                )
            }
        }
    }

    @ViewBuilder
    private var registryContent: some View {
        if selectedTab == "skills" {
            skillsSection
        } else {
            mcpSection
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Picker("", selection: $selectedTab) {
                Text("Skillet（\(canonicalSkills.count)）").tag("skills")
                Text("MCP（\(visibleMCPEntries.count)）").tag("mcp")
                Text("Pocket").tag("pocket")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 440)
            .onChange(of: selectedTab) { _, tab in
                showingAddForm = false
                draftKind = tab == "skills" ? .skill : .mcp
            }
            Spacer()
            if selectedTab == "mcp" {
                Button {
                    Task { await refreshMCP(force: true) }
                } label: {
                    Label(isProbing ? "探測中" : "重新探活", systemImage: "arrow.clockwise")
                }
                .disabled(isProbing)
                .buttonStyle(.bordered)
                Button {
                    syncToClaude()
                } label: {
                    Label(isSyncingClaude ? "同步中" : "同步到 Claude", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isSyncingClaude)
                .buttonStyle(.bordered)
            }
            if selectedTab != "pocket" {
                Button {
                    showingAddForm.toggle()
                } label: {
                    Label(showingAddForm ? "收合" : "新增", systemImage: showingAddForm ? "chevron.up" : "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(LiquidGlassTokens.brandAccent)
            }
        }
        .padding(.horizontal, 2)
    }

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if visibleMCPEntries.isEmpty {
                sectionEmptyHint("尚無 MCP 登錄")
            }
            ForEach(visibleMCPEntries) { entry in
                PluginConnectionCard(entry: entry) { confirmMCPRemoval(entry) }
            }
        }
        .task {
            while !Task.isCancelled {
                await refreshMCP(force: false)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    private var visibleMCPEntries: [PluginRegistryEntry] {
        refreshedMCPEntries ?? (entries.filter { $0.kind == .builtin } + partition.mcp)
    }

    @MainActor private func refreshMCP(force: Bool) async {
        guard !isProbing else { return }
        let environment = ProcessInfo.processInfo.environment
        guard !PluginsSource.isExport(environment) else { return }
        isProbing = true
        defer { isProbing = false }
        refreshedMCPEntries = visibleMCPEntries.map {
            var entry = $0
            if entry.kind == .mcp && entry.liveness.state != .disabled {
                entry.liveness = .init(state: .probing)
            }
            return entry
        }
        let fresh = await Task.detached(priority: .utility) {
            PluginsSource.refreshNow(environment: environment, force: force)
        }.value
        let builtins = await Task.detached(priority: .utility) {
            let runtime = await BuiltinPluginRuntimeSnapshot.current()
            return PluginsSource.builtinEntries(environment: environment, runtime: runtime)
        }.value
        refreshedMCPEntries = builtins + fresh.filter { $0.kind == .mcp }
    }

    private func confirmMCPRemoval(_ entry: PluginRegistryEntry) {
        guard entry.kind == .mcp, entry.liveness.state == .unreachable else { return }
        Task { @MainActor in
            guard await IslandNotice.shared.confirm(title: "移除外掛登記？",
                detail: "\(entry.name)・只移除設定登記並保留 .bak；不刪程式、不停止既有對話。",
                confirmLabel: "移除登記", timeout: 30) else { return }
            remove(entry)
            refreshedMCPEntries = nil
            await refreshMCP(force: true)
        }
    }

    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Skillet 私有能力倉庫")
                        .font(.headline)
                    Text("本機 canonical skill 以 revision 管理；操作只寫 staging，不直接 promotion。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Badge("staging only")
            }
            canonicalSkillsBlock
            externalStagingSkillsBlock
        }
        .onAppear {
            if !hasScannedCanonical {
                hasScannedCanonical = true
                scanCanonicalSkills()
            }
        }
    }

    // MARK: - Canonical skills directory

    private var canonicalSkillsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.subheadline)
                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                Text("Repositories")
                    .font(.subheadline.weight(.semibold))
                if canonicalRootAvailable {
                    Badge("\(canonicalSkills.count)")
                }
                Text(skillsDirectoryCatalog.rootURL.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    scanCanonicalSkills()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(isScanningCanonical)
                .help("重新掃描 canonical 技能庫目錄")
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)

            if !canonicalRootAvailable {
                sectionEmptyHint(
                    "canonical/runtime 技能庫目錄不可用（\(canonicalFailureLabel)）；"
                        + "store-only repository 仍保留。"
                )
            }
            let visibleSkills = canonicalRootAvailable
                ? canonicalSkills
                : canonicalSkills.filter { $0.path.isEmpty }
            if visibleSkills.isEmpty {
                sectionEmptyHint(isScanningCanonical ? "掃描中…" : "Skillet canonical 目錄是空的")
            } else {
                ForEach(visibleSkills) { canonicalSkillRow($0) }
            }
        }
    }

    private var canonicalFailureLabel: String {
        switch canonicalReadFailure {
        case .volumeAbsent: return "volume-absent"
        case .permissionDenied: return "permission-denied"
        case .ioError: return "io-error"
        case nil: return "unavailable"
        }
    }

    private func canonicalSkillRow(_ skill: TatwoSkillsDirectoryEntryV1) -> some View {
        let isExpanded = expandedCanonicalIDs.contains(skill.id)
        let summary = canonicalSummaries[skill.id]
        return GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    toggleCanonicalDetail(skill)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "shippingbox")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(LiquidGlassTokens.brandAccent)
                            .frame(width: 34, height: 34)
                            .background(
                                LiquidGlassTokens.brandAccent.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 7) {
                                Text(skill.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                if skill.isRegistered {
                                    Badge("staging")
                                } else {
                                    Badge("draft")
                                }
                                if !skill.hasManifest {
                                    Badge("無 SKILL.md")
                                }
                                if skill.usesLinkedSnapshotSource {
                                    Badge("連結來源")
                                }
                                if let summary {
                                    Badge(summary.reconciliationState.rawValue)
                                }
                            }
                            Text(skill.summary ?? skill.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }

                        Spacer(minLength: 8)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let summary {
                    SkilletRepositoryFacts(summary: summary)
                    Text(summary.reconciliationDetail)
                        .font(.caption2)
                        .foregroundStyle(
                            summary.reconciliationState == .verified
                                ? Color.secondary
                                : (
                                    summary.reconciliationState == .unreadable
                                        ? Color.red
                                        : Color.orange
                                )
                        )
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("建立本機 revision 索引…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        stageCanonicalSkill(skill)
                    } label: {
                        if snapshottingCanonicalIDs.contains(skill.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(
                                summary?.isStaged == true
                                    ? "staging 已快照"
                                    : (summary?.hasSnapshot == true ? "加入 staging" : "建立 snapshot"),
                                systemImage: summary?.isStaged == true
                                    ? "checkmark.circle"
                                    : "tray.and.arrow.down"
                            )
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(
                        summary?.isStaged == true
                            || snapshottingCanonicalIDs.contains(skill.id)
                            || !skill.hasManifest
                    )

                    Text("不提供 canary / stable 直升按鈕；promotion 必須走 Work OS gate。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }

                if isExpanded {
                    Divider()
                    skilletDetail(skill: skill, summary: summary)
                    .transition(.opacity)
                }
            }
        }
        .animation(.spring(response: 0.30, dampingFraction: 0.82), value: isExpanded)
    }

    private func toggleCanonicalDetail(_ skill: TatwoSkillsDirectoryEntryV1) {
        if expandedCanonicalIDs.contains(skill.id) {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                _ = expandedCanonicalIDs.remove(skill.id)
            }
            return
        }
        _ = withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
            expandedCanonicalIDs.insert(skill.id)
        }
        guard canonicalDetailCache[skill.id] == nil else { return }
        let storeRoot = skilletRepositoryStore.rootURL
        Task {
            let detail = await Task.detached(priority: .utility) {
                let store = TatwoSkilletRepositoryStore(rootURL: storeRoot)
                guard let repository = try? store.loadRepository(id: skill.id),
                      let revisionID = repository.canonicalRevision,
                      let manifest = try? store.loadSnapshotManifest(
                          repositoryID: skill.id,
                          revisionID: revisionID
                      )
                else {
                    return SkilletPresentationBuilder.loadRuntimeDetail(skill: skill)
                }
                return SkilletPresentationBuilder.loadDetail(
                    revisionID: revisionID,
                    snapshotManifest: manifest
                )
            }.value
            canonicalDetailCache[skill.id] = detail
        }
    }

    private func scanCanonicalSkills() {
        guard !isScanningCanonical else { return }
        isScanningCanonical = true
        let catalog = skillsDirectoryCatalog
        let registeredPaths = Set(
            entries.compactMap { $0.path?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let storeRoot = skilletRepositoryStore.rootURL
        let expandedIDs = expandedCanonicalIDs
        Task {
            let (available, failure, scanned, summaries, details) = await Task.detached(priority: .utility) {
                let scanResult = catalog.scanOutcome(registeredPaths: registeredPaths)
                let available = scanResult.value != nil
                let failure = scanResult.failure
                let runtimeEntries = scanResult.value ?? []
                let store = TatwoSkilletRepositoryStore(rootURL: storeRoot)
                let repositoryInventory = Self.skilletRepositoryInventory(rootURL: storeRoot)
                var repositoryDisplayNames: [String: String] = [:]
                for id in repositoryInventory.ids.sorted()
                    where repositoryInventory.issues[id] == nil
                {
                    if let repository = try? store.loadRepository(id: id) {
                        repositoryDisplayNames[id] = repository.displayName
                    }
                }
                let runtimeByID = SkilletRuntimeCatalogReconciler.reconcile(
                    runtimeEntries: runtimeEntries,
                    repositoryDisplayNames: repositoryDisplayNames
                )
                let allIDs = Set(runtimeByID.keys).union(repositoryInventory.ids)
                var summaries: [String: SkilletRepositorySummary] = [:]
                var details: [String: SkilletRepositoryDetail] = [:]
                var allSkills: [TatwoSkillsDirectoryEntryV1] = []
                for id in allIDs.sorted() {
                    var repository: TatwoCapabilityRepositoryV1?
                    var receipts: [TatwoSkilletRepositoryReceiptV1] = []
                    var mergeProposals: [TatwoMergeProposalV1] = []
                    var mergeConflictsByProposal:
                        [String: [TatwoSkilletMergeConflictArtifactV1]] = [:]
                    var unreadableReason = repositoryInventory.issues[id]
                    if repositoryInventory.ids.contains(id), unreadableReason == nil {
                        do {
                            repository = try store.loadRepository(id: id)
                            receipts = try store.loadReceipts(repositoryID: id)
                            mergeProposals = try store.loadMergeProposals(
                                repositoryID: id
                            )
                            for proposal in mergeProposals {
                                mergeConflictsByProposal[proposal.id] =
                                    try store.loadMergeConflicts(
                                        repositoryID: id,
                                        proposalID: proposal.id
                                    )
                            }
                        } catch {
                            unreadableReason = error.localizedDescription
                        }
                    }
                    let skill = runtimeByID[id] ?? TatwoSkillsDirectoryEntryV1(
                        id: id,
                        name: repository?.displayName ?? id,
                        summary: repository?.summary,
                        path: "",
                        hasManifest: false,
                        isRegistered: false
                    )
                    allSkills.append(skill)
                    summaries[id] = SkilletPresentationBuilder.makeSummary(
                        skill: skill,
                        repository: repository,
                        receipts: receipts,
                        mergeProposals: mergeProposals,
                        mergeConflictsByProposal: mergeConflictsByProposal,
                        runtimePresent: runtimeByID[id] != nil,
                        unreadableReason: unreadableReason
                    )
                    if unreadableReason == nil,
                       let revisionID = repository?.canonicalRevision,
                       let manifest = try? store.loadSnapshotManifest(
                           repositoryID: id,
                           revisionID: revisionID
                       )
                    {
                        details[id] = SkilletPresentationBuilder.loadDetail(
                            revisionID: revisionID,
                            snapshotManifest: manifest
                        )
                    } else {
                        // Preserve expanded detail across refresh and tab re-entry.
                        if expandedIDs.contains(id) {
                            details[id] = SkilletPresentationBuilder.loadRuntimeDetail(skill: skill)
                        }
                    }
                }
                let sortedSkills = allSkills.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return (available, failure, sortedSkills, summaries, details)
            }.value
            let applyResults = {
                canonicalRootAvailable = available
                canonicalReadFailure = failure
                canonicalSkills = scanned
                canonicalSummaries = summaries
                // A row may have been expanded while the background scan was running.
                let newlyExpanded = expandedCanonicalIDs.subtracting(expandedIDs)
                let recentDetails = canonicalDetailCache.filter { newlyExpanded.contains($0.key) }
                canonicalDetailCache = details.merging(recentDetails) { scanned, _ in scanned }
                if let snapshotDetailTab {
                    expandedCanonicalIDs = Set(scanned.map(\.id))
                    canonicalDetailTabs = Dictionary(
                        uniqueKeysWithValues: scanned.map {
                            ($0.id, snapshotDetailTab)
                        }
                    )
                }
            }
            if isSnapshotExport {
                applyResults()
            } else {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                    applyResults()
                }
            }
            isScanningCanonical = false
        }
    }

    @ViewBuilder
    private func skilletDetail(
        skill: TatwoSkillsDirectoryEntryV1,
        summary: SkilletRepositorySummary?
    ) -> some View {
        Picker(
            "",
            selection: Binding(
                get: { canonicalDetailTabs[skill.id] ?? .files },
                set: { canonicalDetailTabs[skill.id] = $0 }
            )
        ) {
            ForEach(SkilletDetailTab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        if let detail = canonicalDetailCache[skill.id] {
            switch canonicalDetailTabs[skill.id] ?? .files {
            case .files:
                skilletFiles(detail)
            case .history:
                skilletHistory(summary)
            case .merges:
                skilletMerges(summary)
            case .devices:
                skilletDevices(summary)
            case .receipts:
                skilletReceipts(summary)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("讀取 repository 詳情…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        }
    }

    @ViewBuilder
    private func skilletMerges(_ summary: SkilletRepositorySummary?) -> some View {
        if let summary, !summary.mergeProposals.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(summary.mergeProposals) { proposal in
                    let conflicts =
                        summary.mergeConflictsByProposal[proposal.id] ?? []
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(
                                systemName: proposal.status == .pending
                                    ? "arrow.triangle.merge"
                                    : (
                                        proposal.status == .approved
                                            ? "checkmark.seal.fill"
                                            : "xmark.seal.fill"
                                    )
                            )
                            .foregroundStyle(
                                proposal.status == .pending
                                    ? Color.orange
                                    : (
                                        proposal.status == .approved
                                            ? Color.green
                                            : Color.red
                                    )
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(proposal.id)
                                    .font(.caption.monospaced().weight(.semibold))
                                    .textSelection(.enabled)
                                Text(
                                    "\(proposal.status.rawValue)"
                                        + " · source \(proposal.sourceDeviceID)"
                                        + " · \(conflicts.count) conflicts"
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if decidingMergeProposalIDs.contains(proposal.id) {
                                ProgressView().controlSize(.small)
                            }
                        }

                        Text(
                            "base \(proposal.baseRevisionID ?? "unrelated")"
                                + "\ncanonical \(proposal.canonicalRevisionID)"
                                + "\nproposed \(proposal.proposedRevisionID)"
                                + "\nmerged \(proposal.mergedRevisionID ?? "requires resolution")"
                        )
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                        if !conflicts.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(conflicts) { conflict in
                                    HStack(alignment: .top, spacing: 7) {
                                        Image(systemName: "exclamationmark.triangle")
                                            .foregroundStyle(.orange)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(conflict.relativePath)
                                                .font(.caption.monospaced().weight(.semibold))
                                            Text(
                                                "\(conflict.kind.rawValue)"
                                                    + " · artifact \(conflict.id)"
                                            )
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                        }

                        if proposal.status == .pending {
                            mergeDecisionControls(
                                proposal: proposal,
                                conflicts: conflicts,
                                repository: summary.repository
                            )
                        } else {
                            Text(
                                "已寫入 \(proposal.status.rawValue) decision；"
                                    + "incoming branch 與 artifacts 保留供重播與稽核。"
                            )
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(8)
                    .background(
                        Color.secondary.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                }
            }
        } else {
            sectionEmptyHint("沒有 merge proposal；分歧不得以 last-write-wins 隱藏。")
        }
    }

    @ViewBuilder
    private func mergeDecisionControls(
        proposal: TatwoMergeProposalV1,
        conflicts: [TatwoSkilletMergeConflictArtifactV1],
        repository: TatwoCapabilityRepositoryV1
    ) -> some View {
        let isDeciding = decidingMergeProposalIDs.contains(proposal.id)
        if !conflicts.isEmpty {
            Picker(
                "Resolved revision",
                selection: Binding(
                    get: {
                        selectedMergeRevisionByProposal[proposal.id] ?? ""
                    },
                    set: {
                        selectedMergeRevisionByProposal[proposal.id] = $0
                    }
                )
            ) {
                Text("選擇人工解決後 revision…").tag("")
                ForEach(repository.revisions) { revision in
                    Text(
                        "\(SkilletPresentationBuilder.shortRevision(revision.id))"
                            + " · \(revision.channel.rawValue)"
                    )
                    .tag(revision.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(isDeciding)
        }

        HStack(spacing: 8) {
            Button {
                let resolved = conflicts.isEmpty
                    ? nil
                    : selectedMergeRevisionByProposal[proposal.id]
                pendingMergeDecision = SkilletMergeDecisionRequest(
                    kind: .approve,
                    repositoryID: proposal.repositoryID,
                    proposalID: proposal.id,
                    resolvedRevisionID: resolved
                )
            } label: {
                Label(
                    conflicts.isEmpty ? "批准 deterministic merge" : "批准 resolved revision",
                    systemImage: "checkmark.seal"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(
                isDeciding
                    || (
                        conflicts.isEmpty
                            ? proposal.mergedRevisionID == nil
                            : (
                                selectedMergeRevisionByProposal[proposal.id]?
                                    .isEmpty ?? true
                            )
                    )
            )

            Button(role: .destructive) {
                pendingMergeDecision = SkilletMergeDecisionRequest(
                    kind: .reject,
                    repositoryID: proposal.repositoryID,
                    proposalID: proposal.id,
                    resolvedRevisionID: nil
                )
            } label: {
                Label("拒絕並保留 branch", systemImage: "xmark.seal")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isDeciding)
        }
    }

    private func performMergeDecision(_ request: SkilletMergeDecisionRequest) {
        pendingMergeDecision = nil
        guard !decidingMergeProposalIDs.contains(request.proposalID) else {
            return
        }
        decidingMergeProposalIDs.insert(request.proposalID)
        statusMessage = request.kind == .approve
            ? "正在批准 merge；先鎖定並 hash runtime…"
            : "正在拒絕 merge；incoming branch 與 conflict artifacts 會保留…"
        let storeRoot = skilletRepositoryStore.rootURL
        let runtimeRoot = skillsDirectoryCatalog.rootURL
        let actor = SkilletMergeDecisionExecutor.currentActor()
        Task {
            let result = await Task.detached(priority: .utility) {
                Result {
                    try SkilletMergeDecisionExecutor.execute(
                        storeRoot: storeRoot,
                        runtimeRoot: runtimeRoot,
                        request: request,
                        decidedBy: actor
                    )
                }
            }.value
            do {
                let decision = try result.get()
                statusMessage =
                    "\(request.repositoryID) merge \(decision.receipt.status.rawValue)"
                    + "；decision \(decision.receipt.id)"
                    + (decision.runtimeUnchanged
                        ? "；runtime readback 前後一致。"
                        : "；runtime 發生變動，結果不可接受。")
            } catch {
                statusMessage = "merge 決策失敗且未宣稱成功：\(error.localizedDescription)"
            }
            decidingMergeProposalIDs.remove(request.proposalID)
            scanCanonicalSkills()
        }
    }

    @ViewBuilder
    private func skilletFiles(_ detail: SkilletRepositoryDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = detail.readError {
                Text("讀取失敗：\(error)").foregroundStyle(.red)
            }
            if detail.liveManifest != nil {
                Text("本機 SKILL.md（即時讀取，非版本快照）").font(.caption).foregroundStyle(.secondary)
            }
            if detail.files.isEmpty {
                sectionEmptyHint("尚未建立 immutable snapshot；Files 不讀 canonical live 目錄冒充 revision。")
            } else {
                ForEach(detail.files) { file in
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(file.relativePath)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(file.sizeLabel)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        if let text = detail.liveManifest {
            Text(text).font(.caption.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func skilletHistory(_ summary: SkilletRepositorySummary?) -> some View {
        if let revisions = summary?.repository.revisions, !revisions.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(revisions) { revision in
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(revision.id)
                                .font(.caption.monospaced().weight(.semibold))
                            Text(
                                "\(revision.channel.rawValue) · "
                                    + revision.createdAt.formatted(date: .abbreviated, time: .shortened)
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                Text("以上 revision 直接來自 Skillet file-backed repository metadata。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else {
            sectionEmptyHint("沒有可驗證 revision history")
        }
    }

    @ViewBuilder
    private func skilletDevices(_ summary: SkilletRepositorySummary?) -> some View {
        if let heads = summary?.repository.deviceHeads, !heads.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(heads) { head in
                    let matchingReceipt = summary?.matchingReceipt(for: head)
                    let verifiedAtText = head.lastVerifiedAt?.formatted(
                        date: .abbreviated,
                        time: .standard
                    ) ?? "missing"
                    let provenanceText = matchingReceipt.map {
                        "deviceHead receipt \($0.id)"
                    } ?? "device head only"
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Label(head.deviceID, systemImage: "laptopcomputer")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(
                                matchingReceipt == nil
                                    ? "receipt-missing"
                                    : "verified"
                            )
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(matchingReceipt == nil ? .orange : .green)
                        }
                        // Built in steps rather than one concatenation: as a single
                        // expression the type-checker times out on slower machines,
                        // which fails the build on some devices but not others.
                        let requestText: String =
                            head.requestID.isEmpty ? "missing" : head.requestID
                        let sequenceText: String =
                            head.ledgerSequence.map(String.init) ?? "missing"
                        let revisionLine: String =
                            "revision \(head.revisionID) · request \(requestText) · epoch \(head.authorityEpoch) · seq \(sequenceText)"
                        Text(revisionLine)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        // Built in steps rather than one concatenation: as a single
                        // expression the type-checker times out on slower machines,
                        // which fails the build on some devices but not others.
                        let verifiedAtText =
                            head.lastVerifiedAt?.formatted(
                                date: .abbreviated,
                                time: .standard
                            ) ?? "missing"
                        let provenanceText =
                            matchingReceipt.map { "deviceHead receipt \($0.id)" }
                            ?? "device head only"
                        Text("verifiedAt \(verifiedAtText) · provenance \(provenanceText)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                    }
                    .padding(7)
                    .background(
                        Color.secondary.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
            }
        } else {
            sectionEmptyHint("0 台設備已回傳 revision ACK；本機 staging 不等於多設備啟用。")
        }
    }

    @ViewBuilder
    private func skilletReceipts(_ summary: SkilletRepositorySummary?) -> some View {
        if let receipts = summary?.receipts, !receipts.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(receipts) { receipt in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.seal")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(receipt.kind.rawValue) · \(receipt.revisionID)")
                                .font(.caption.monospaced().weight(.semibold))
                            // Same timeout shape as skilletDevices revision line:
                            // `+` plus `.map` closures fails Swift 6.3 type-check.
                            let receiptRequestText: String = receipt.requestID ?? "n/a"
                            let receiptEpochText: String =
                                receipt.authorityEpoch.map(String.init) ?? "n/a"
                            let receiptSequenceText: String =
                                receipt.ledgerSequence.map(String.init) ?? "n/a"
                            let receiptLine: String =
                                "device \(receipt.deviceID ?? "n/a") · request \(receiptRequestText) · epoch \(receiptEpochText) · seq \(receiptSequenceText)"
                            Text(receiptLine)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            Text(receipt.message)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(
                                "verifiedAt "
                                    + receipt.recordedAt.formatted(
                                        date: .abbreviated,
                                        time: .standard
                                    )
                                    + " · provenance Skillet file-backed receipt"
                            )
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        } else {
            sectionEmptyHint("尚無 file-backed receipts；建立 snapshot 後才會出現。")
        }
    }

    private var externalStagingSkillsBlock: some View {
        let canonicalPaths = Set(canonicalSkills.map { standardizedPath($0.path) })
        let external = partition.skills.filter { entry in
            guard let path = entry.path else { return true }
            return !canonicalPaths.contains(standardizedPath(path))
        }
        return Group {
            if !external.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("外部 staging 登錄")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 4)
                    ForEach(external) { registryRow($0) }
                }
            }
        }
    }

    private func stageCanonicalSkill(_ skill: TatwoSkillsDirectoryEntryV1) {
        guard !snapshottingCanonicalIDs.contains(skill.id) else { return }
        snapshottingCanonicalIDs.insert(skill.id)
        statusMessage = "正在驗證並建立 \(skill.name) immutable snapshot…"
        let storeRoot = skilletRepositoryStore.rootURL
        let repositoryID = skill.id
        let displayName = skill.name
        let repositorySummary = skill.summary ?? "Skillet capability repository"
        let sourceDirectory = skill.snapshotSourceURL
        let shouldRegister = !skill.isRegistered
        Task {
            let snapshotResult = await Task.detached(priority: .utility) {
                Result {
                    try TatwoSkilletRepositoryStore(rootURL: storeRoot)
                        .snapshotCanonicalSkillDirectory(
                            repositoryID: repositoryID,
                            displayName: displayName,
                            summary: repositorySummary,
                            sourceDirectory: sourceDirectory,
                            channel: .staging
                        )
                }
            }.value
            do {
                let revision = try snapshotResult.get()
                if shouldRegister {
                    try onRegister(.skill, skill.path, repositorySummary, displayName)
                }
                statusMessage = "\(skill.name) 已建立 "
                    + "\(SkilletPresentationBuilder.shortRevision(revision.id)) snapshot"
                    + (shouldRegister ? " 並加入 staging registry。" : "；既有 staging registry 保留。")
                    + " 尚未進入 canary / stable。"
            } catch {
                statusMessage = "snapshot/staging 失敗：\(error.localizedDescription)"
            }
            snapshottingCanonicalIDs.remove(skill.id)
            scanCanonicalSkills()
        }
    }

    private func standardizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    nonisolated private static func skilletRepositoryInventory(
        rootURL: URL
    ) -> (ids: Set<String>, issues: [String: String]) {
        let repositories = rootURL.appendingPathComponent(
            "repositories",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: repositories.path) else {
            return ([], [:])
        }
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: repositories,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (
                [],
                ["repositories": "Skillet repositories 目錄無法讀取。"]
            )
        }
        var ids = Set<String>()
        var issues: [String: String] = [:]
        for candidate in candidates {
            let id = candidate.lastPathComponent
            ids.insert(id)
            guard DeviceSyncReceipt.isSafeIdentifier(id) else {
                issues[id] = "repository id 不安全。"
                continue
            }
            do {
                let values = try candidate.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    issues[id] = "repository entry 不是安全的 regular directory。"
                    continue
                }
            } catch {
                issues[id] = error.localizedDescription
            }
        }
        return (ids, issues)
    }

    private func sectionEmptyHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
    }

    private var addForm: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Picker("類型", selection: $draftKind) {
                        Text("skill").tag(RegistryKind.skill)
                        Text("MCP").tag(RegistryKind.mcp)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)

                    TextField("顯示名稱（可留空自動從路徑取名）", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 8) {
                    TextField("貼上 skill / MCP 路徑", text: $draftPath)
                        .textFieldStyle(.roundedBorder)
                    Button("選擇…") { choosePath() }
                }

                TextField("白話用途（必填，例如：改多檔前先查影響範圍的地圖工具）", text: $draftPurpose)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Text("不碰 gateway runtime；只寫本機 staging 登錄檔。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("登記") { register() }
                        .disabled(!canRegister)
                        .buttonStyle(.borderedProminent)
                        .tint(LiquidGlassTokens.brandAccent)
                }
            }
        }
    }

    private func registryRow(_ entry: PluginRegistryEntry) -> some View {
        PluginRegistrySwipeRow(entry: entry) {
            pendingRemoval = entry
        } content: {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: icon(for: entry.kind))
                    .font(.title2)
                    .frame(width: 42, height: 42)
                    .tatwoAdaptiveMaterial(cornerRadius: 14)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(entry.name)
                            .font(.headline)
                        Badge(kindLabel(entry.kind))
                        Badge(entry.safetyLevel.rawValue)
                    }
                    Text(entry.purpose)
                        .foregroundStyle(.secondary)
                    Label(pathLabel(entry), systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Label(entry.trigger, systemImage: "bolt.horizontal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let smokeCommand = entry.smokeCommand {
                        Label(smokeCommand, systemImage: "stethoscope")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(entry.publicInstallHint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 10)
                VStack(alignment: .trailing, spacing: 8) {
                    StatusPill(state: entry.installState)
                }
            }
        }
    }

    private func register() {
        do {
            try onRegister(draftKind, draftPath, draftPurpose, draftName.isEmpty ? nil : draftName)
            statusMessage = "已登記；Scenario 編輯器與工作筐會讀同一份 registry。"
            draftName = ""
            draftPath = ""
            draftPurpose = ""
            showingAddForm = false
        } catch {
            statusMessage = "登記失敗：\(error.localizedDescription)"
        }
    }

    private func remove(_ entry: PluginRegistryEntry) {
        do {
            try onRemove(entry)
            statusMessage = "已移除 \(entry.name)。"
        } catch {
            statusMessage = "移除失敗：\(error.localizedDescription)"
        }
        pendingRemoval = nil
    }

    private func syncToClaude() {
        isSyncingClaude = true
        statusMessage = "正在背景同步到 Claude MCP config；若目標檔已存在會先寫 .bak 備份。"
        Task {
            do {
                let receipt = try await onSyncClaude()
                await MainActor.run {
                    isSyncingClaude = false
                    let backup = receipt.backupPath.map { "；備份：\($0)" } ?? ""
                    let serverList = receipt.serverNames.joined(separator: ", ")
                    statusMessage = "Claude MCP 已同步：\(serverList) → \(receipt.wrotePath)\(backup)"
                }
            } catch {
                await MainActor.run {
                    isSyncingClaude = false
                    statusMessage = "Claude MCP 同步失敗：\(error.localizedDescription)。可先用 CLI 匯出 staging，再手動合併到 ~/.claude.json。"
                }
            }
        }
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "選擇 skill 或 MCP 入口路徑"
        if TatwoModalPanelGate.run({ panel.runModal() }) == .OK, let url = panel.url {
            draftPath = url.path
        }
    }

    private func pathLabel(_ entry: PluginRegistryEntry) -> String {
        entry.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        ? (entry.path ?? "")
        : "未填路徑；提示：\(entry.publicInstallHint)"
    }

    private func kindLabel(_ kind: RegistryKind) -> String {
        switch kind {
        case .mcp: return "MCP"
        case .skill: return "skill"
        default: return kind.rawValue
        }
    }

    private func icon(for kind: RegistryKind) -> String {
        switch kind {
        case .plugin: "puzzlepiece.extension"
        case .skill: "book.closed"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .app: "app.connected.to.app.below.fill"
        case .localRuntime: "server.rack"
        case .builtin: "shippingbox"
        }
    }
}

struct PluginRegistrySwipeRow<Content: View>: View {
    let entry: PluginRegistryEntry
    let requestRemoval: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var offsetX: CGFloat = 0
    @State private var isOpen = false

    private let revealWidth: CGFloat = 92
    private var revealedWidth: CGFloat {
        min(revealWidth, max(0, -offsetX))
    }
    private var revealProgress: CGFloat {
        revealWidth == 0 ? 0 : revealedWidth / revealWidth
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive) {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                    offsetX = 0
                    isOpen = false
                }
                requestRemoval()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(LinearGradient(colors: [.red.opacity(0.92), .red.opacity(0.72)], startPoint: .top, endPoint: .bottom))
                    Label("移除", systemImage: "trash.fill")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.white)
                }
                .frame(width: revealedWidth)
                .frame(maxHeight: .infinity)
                .opacity(revealProgress)
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
            .allowsHitTesting(isOpen && revealProgress > 0.95)

            GlassCard {
                content()
            }
            .offset(x: offsetX)
            .contentShape(Rectangle())
            .background(NonWindowDraggingView())
            .highPriorityGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onChanged { value in
                        guard abs(value.translation.width) >= abs(value.translation.height) else { return }
                        let base: CGFloat = isOpen ? -revealWidth : 0
                        let proposed = base + value.translation.width
                        offsetX = min(0, max(-revealWidth, proposed))
                    }
                    .onEnded { value in
                        guard abs(value.translation.width) >= abs(value.translation.height) else { return }
                        let shouldOpen = offsetX < -revealWidth * 0.45 || value.predictedEndTranslation.width < -revealWidth
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.76, blendDuration: 0.06)) {
                            isOpen = shouldOpen
                            offsetX = shouldOpen ? -revealWidth : 0
                        }
                    }
            )
            .animation(.spring(response: 0.34, dampingFraction: 0.80), value: isOpen)
            .accessibilityAction(named: Text("移除")) {
                requestRemoval()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .help("整列向左滑出紅色移除鈕；點擊後仍會二次確認。")
    }
}

struct NonWindowDraggingView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NonWindowDraggingNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class NonWindowDraggingNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}
