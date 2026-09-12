import SwiftUI
import AppKit
import TatwoUltraworkCore

struct TraitsPage: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let dimensions: [TraitEvaluationDimension]
    let modelTraits: [ModelTrait]
    @State private var selectedLeadModelID = "opus-5"
    @State private var selectedSecondaryModelID = "gpt-5.5"
    @State private var selectedSubModelID = "minimax-m3"
    @State private var selectedScoreModelID = "opus-5"
    @State private var selectedEvidenceModelID = "fable-5"
    @State private var showSingleModelSection = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_TRAITS_COLLAPSE_SINGLE"] != "1"
    @State private var showCollaborationSection = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_TRAITS_COLLAPSE_COLLAB"] != "1"
    @State private var showCollaborationVisual = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_TRAITS_SHOW_VISUAL"] == "1"
    @State private var showScoringStandards = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_TRAITS_SHOW_RUBRIC"] == "1"
    @State private var showScorePauseSection = true

    private var profiles: [ModelScoreProfile] {
        let traitsByID = Dictionary(uniqueKeysWithValues: modelTraits.map { ($0.id, $0) })
        return Self.visibleTraitModelIDs.compactMap { id in
            traitsByID[id].map { ModelScoreProfile(trait: $0, dimensions: dimensions) }
        }
    }

    private var roleOptions: [ModelSelectOption] {
        profiles
            .filter { $0.id != "fable-5" }
            .map { ModelSelectOption(id: $0.id, name: $0.name, subtitle: $0.subtitle) }
    }

    private var leadOptions: [ModelSelectOption] {
        let leadIDs = Set(TeamRoutingCatalog.leadStrategies.map(\.leadModelID))
        let modelOptions = profiles
            .filter { leadIDs.contains($0.id) }
            .map { ModelSelectOption(id: $0.id, name: $0.name, subtitle: $0.subtitle) }
        return [Self.autoLeadOption, Self.noModelOption] + modelOptions
    }

    private var optionalRoleOptions: [ModelSelectOption] {
        [Self.noModelOption] + roleOptions
    }

    private var scoreOptions: [ModelSelectOption] {
        profiles.map { ModelSelectOption(id: $0.id, name: $0.name, subtitle: $0.subtitle) }
    }

    private var selectedScoreProfile: ModelScoreProfile? {
        profile(id: selectedScoreModelID) ?? profiles.first
    }

    private var arenaEvidenceByModelSlug: [String: TatwoWebArenaModelEvidence] {
        Dictionary(uniqueKeysWithValues: TatwoWebArenaFactory.importedModelEvidence.map { ($0.modelSlug, $0) })
    }

    private var threeDEvidenceByModelSlug: [String: Tatwo3DModelingArenaModelEvidence] {
        Dictionary(uniqueKeysWithValues: Tatwo3DModelingArenaFactory.importedModelEvidence.map { ($0.modelSlug, $0) })
    }

    private var evidenceModels: [TraitEvidenceDisplayModel] {
        let profileByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let discoveredIDs = Self.evidenceModelOrder
            + profiles.map(\.id)
            + TatwoWebArenaFactory.importedModelEvidence.map(\.modelSlug)
            + Tatwo3DModelingArenaFactory.importedModelEvidence.map(\.modelSlug)
        var seen = Set<String>()
        return discoveredIDs.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            if let profile = profileByID[id] {
                return TraitEvidenceDisplayModel(id: id, displayName: profile.name, subtitle: profile.subtitle)
            }
            if let evidence = arenaEvidenceByModelSlug[id] {
                return TraitEvidenceDisplayModel(id: id, displayName: evidence.displayName, subtitle: "Web Arena receipt")
            }
            return TraitEvidenceDisplayModel(id: id, displayName: Self.displayName(forEvidenceModelID: id), subtitle: Self.subtitle(forEvidenceModelID: id))
        }
    }

    private func profile(id: String) -> ModelScoreProfile? {
        guard id.hasPrefix("__") == false else { return nil }
        return profiles.first { $0.id == id }
    }

    private static let autoLeadOption = ModelSelectOption(
        id: "__auto_lead__",
        name: "依情境自動",
        subtitle: "不手動指定主導，讓情境/模式規則決定"
    )

    private static let noModelOption = ModelSelectOption(
        id: "__none__",
        name: "不指定",
        subtitle: "此身份暫不啟用"
    )

    private static let visibleTraitModelIDs: [String] = [
        "fable-5",
        "gpt-5.5",
        "opus-5",
        "sonnet-5",
        "minimax-m3",
        "grok-build",
        "chatgpt-pro-mcp",
        "local-qwen-ollama"
    ]

    private static let evidenceModelOrder: [String] = [
        "fable-5",
        "gpt-5.6",
        "gpt-5.5",
        "gpt-5.4",
        "opus-5",
        "sonnet-5",
        "minimax-m3",
        "grok-build",
        "haiku-4-5",
        "chatgpt-pro-mcp",
        "local-qwen-ollama"
    ]

    private static func displayName(forEvidenceModelID id: String) -> String {
        switch id {
        case "gpt-5.6": return "GPT-5.6"
        case "gpt-5.4": return "GPT-5.4"
        case "haiku-4-5": return "Haiku"
        default: return id
        }
    }

    private static func subtitle(forEvidenceModelID id: String) -> String {
        switch id {
        case "gpt-5.6": return "待正式可用 / 待沙盒"
        case "gpt-5.4": return "次級 GPT route / 已有 Web Arena receipt"
        case "haiku-4-5": return "輕量 sub / 待沙盒"
        default: return "待沙盒測試"
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            // T5: 考試實證特質卡置頂 — 有收據的模型才有卡，白話長短板 10 秒可讀。
            TraitCardsSection()

            TraitFolderSection(
                title: "協作評分",
                subtitle: "人工評價與未來考場證據同區，人工優先",
                icon: "person.3.sequence.fill",
                badge: "\(TeamRoutingCatalog.collaborationEvidence.count)筆",
                isExpanded: $showCollaborationSection
            ) {
                CollaborationEvidenceScoreSection(evidence: TeamRoutingCatalog.collaborationEvidence)
            }

            TraitFolderSection(
                title: "模型評分凍結",
                subtitle: "等待沙盒跑分",
                icon: "pause.circle.fill",
                badge: "no score",
                isExpanded: $showScorePauseSection
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("模型特質證據板：全部模型 × \(dimensions.count) 項", systemImage: "checklist.checked")
                            .font(.caption.weight(.black))
                            .foregroundStyle(.secondary)
                        TraitEvidenceOverviewBoard(
                            models: evidenceModels,
                            selectedID: $selectedEvidenceModelID,
                            webEvidenceByModelSlug: arenaEvidenceByModelSlug,
                            threeDEvidenceByModelSlug: threeDEvidenceByModelSlug,
                            dimensions: dimensions
                        )

                        if let selectedModel = evidenceModels.first(where: { $0.id == selectedEvidenceModelID }) ?? evidenceModels.first {
                            WebArenaEvidenceTile(
                                model: selectedModel,
                                webEvidence: arenaEvidenceByModelSlug[selectedModel.id],
                                threeDEvidence: threeDEvidenceByModelSlug[selectedModel.id],
                                dimensions: dimensions
                            )
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            TraitFolderSection(
                title: "評分表",
                subtitle: "只保留標準，不給模型打分",
                icon: "list.bullet.rectangle.portrait",
                badge: "\(dimensions.count) 項",
                isExpanded: $showScoringStandards
            ) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 185), spacing: 9)], spacing: 9) {
                    ForEach(Array(dimensions.enumerated()), id: \.element.id) { index, dimension in
                        TraitStandardTile(index: index + 1, dimension: dimension)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy(duration: 0.22), value: showSingleModelSection)
        .animation(.snappy(duration: 0.22), value: showCollaborationSection)
        .animation(.snappy(duration: 0.22), value: showCollaborationVisual)
        .animation(.snappy(duration: 0.22), value: showScoringStandards)
    }
}

struct TraitEvidenceDisplayModel: Identifiable, Equatable {
    let id: String
    let displayName: String
    let subtitle: String
}

struct CollaborationEvidenceScoreSection: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let evidence: [TatwoCollabEvidenceV1]
    @State private var humanRatings: [TatwoHumanCollabRatingV1] = []
    @State private var showAddEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    collabHeaderText
                    Spacer(minLength: 8)
                    addRatingButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    collabHeaderText
                    addRatingButton
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showAddEditor {
                HumanCollabRatingEditor {
                    showAddEditor = false
                    reload()
                }
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(evidence) { item in
                    CollabBarRow(item: item)
                }
                ForEach(humanRatings) { rating in
                    HumanCollabRatingRow(rating: rating, onChanged: reload)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .task { reload() }
    }


    private var collabHeaderText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("協作評分")
                .font(.system(size: 15, weight: .black, design: .rounded))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], alignment: .leading, spacing: 5) {
                collabLegendDot(.gray, "基線")
                collabLegendDot(.green, "補強段")
                collabLegendDot(.red, "落後段")
                collabLegendDot(humanRatingColor, "人工")
            }
        }
    }

    private var addRatingButton: some View {
        Button {
            showAddEditor = true
        } label: {
            Text("+人工評分")
                .font(.system(size: 12, weight: .black, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .frame(height: 23)
                .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusChip)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: .continuous))
    }

    private func reload() {
        humanRatings = TatwoHumanCollabRatingStore.default().all()
    }

    private func collabLegendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
        }
    }
}

/// 協作對比條：上=強基線（灰），下=組合條（成員色分段；勝加補強段、負補紅落後段、持平等長）。
struct CollabBarRow: View {
    let item: TatwoCollabEvidenceV1

    private var verdictColor: Color {
        switch item.deltaDirection {
        case .positive: .green
        case .flat: .gray
        case .negative: .red
        }
    }

    private var sourceBadge: String {
        switch item.source {
        case .sandboxExam: "考場"
        case .liveRunHumanVerdict: "人工"
        }
    }

    private var sourceColor: Color {
        switch item.source {
        case .sandboxExam: .teal
        case .liveRunHumanVerdict: humanRatingColor
        }
    }

    private var memberColors: [Color] {
        item.members.map { traitModelColor($0.model) }
    }

    private var combinationText: String {
        item.members.map { "\($0.model)（\($0.role)）" }.joined(separator: "＋")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 8) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 4)], alignment: .leading, spacing: 4) {
                        ForEach(Array(item.members.enumerated()), id: \.offset) { index, member in
                            Text("\(index > 0 ? "＋" : "")\(member.model)（\(member.role)）")
                                .font(.system(size: 13, weight: .black, design: .rounded))
                                .foregroundStyle(traitModelColor(member.model))
                                .lineLimit(1)
                                .minimumScaleFactor(0.74)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 6) {
                        Text(item.qualitativeVerdict)
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .foregroundStyle(verdictColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(verdictColor.opacity(0.13), in: Capsule())
                        Text(sourceBadge)
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .foregroundStyle(sourceColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(sourceColor.opacity(0.12), in: Capsule())
                    }
                    .layoutPriority(1)
                }
                Text(item.taskClass)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            CollabComparativeBars(
                baselineLabel: item.strongBaseline,
                comboLabel: item.weakBaseline.isEmpty ? "組合" : item.weakBaseline,
                memberColors: memberColors,
                delta: item.deltaDirection)

            Text(item.note)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

struct CollabComparativeBars: View {
    let baselineLabel: String
    let comboLabel: String
    let memberColors: [Color]
    let delta: TatwoCollabDeltaDirectionV1

    private let baseFraction: CGFloat = 0.62
    private let deltaFraction: CGFloat = 0.16

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            barRow(label: baselineLabel, trailing: nil) { width in
                Capsule()
                    .fill(Color.gray.opacity(0.55))
                    .frame(width: width * baseFraction)
            }
            barRow(label: comboLabel, trailing: delta == .negative ? "落後" : nil) { width in
                let comboWidth = width * (delta == .negative
                    ? baseFraction - deltaFraction
                    : baseFraction + (delta == .positive ? deltaFraction : 0))
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(LinearGradient(
                            colors: [Color.orange, Color.red.opacity(0.85)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(comboWidth, 3))
                    if delta == .negative {
                        Rectangle().fill(Color.red.opacity(0.25))
                            .frame(width: width * deltaFraction)
                    }
                }
                .clipShape(Capsule())
            }
        }
    }

    private func barRow<Content: View>(
        label: String, trailing: String?, @ViewBuilder bar: @escaping (CGFloat) -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                GeometryReader { geo in
                    HStack(spacing: 0) { bar(geo.size.width) }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 10)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .foregroundStyle(.red)
                        .layoutPriority(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 人工協作加評列：藍色語彙、可刪（有確認）。
struct HumanCollabRatingRow: View {
    let rating: TatwoHumanCollabRatingV1
    let onChanged: () -> Void
    @State private var confirmDelete = false

    private var verdictColor: Color {
        switch rating.deltaDirection {
        case "positive": humanRatingColor
        case "negative": .gray
        default: .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Text(rating.comboLabel)
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(rating.verdict)
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.055), in: Capsule())
                    .layoutPriority(1)
                Button {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .confirmationDialog("刪除這筆人工協作評分？", isPresented: $confirmDelete) {
                    Button("刪除", role: .destructive) {
                        _ = try? TatwoHumanCollabRatingStore.default().remove(id: rating.id)
                        onChanged()
                    }
                }
            }
            HumanOverlayScoreBar(deltaDirection: rating.deltaDirection)
            if !rating.note.isEmpty {
                Text(rating.note)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .help(rating.note.isEmpty ? rating.ratedAt : "\(rating.note) · \(rating.ratedAt)")
    }
}

/// Round 9：人工評分不再並列藍章；改疊到分數條末端。
/// positive = 人工值高於考場值，條尾接藍色延伸段；flat/negative = 在條上用藍色刻痕標記人工位置。
struct HumanOverlayScoreBar: View {
    let deltaDirection: String

    private let examFraction: CGFloat = 0.62
    private var manualFraction: CGFloat {
        switch deltaDirection {
        case "positive": return 0.80
        case "negative": return 0.48
        default: return 0.62
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(
                        colors: [Color.gray.opacity(0.36), Color.gray.opacity(0.58)],
                        startPoint: .leading,
                        endPoint: .trailing))
                    .frame(width: width * examFraction, height: 8)
                if manualFraction > examFraction {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: width * examFraction)
                        Capsule()
                            .fill(humanRatingColor.opacity(0.82))
                            .frame(width: width * (manualFraction - examFraction), height: 8)
                    }
                } else {
                    Capsule()
                        .fill(humanRatingColor)
                        .frame(width: 4, height: 14)
                        .offset(x: max(0, width * manualFraction - 2), y: -3)
                }
            }
        }
        .frame(height: 14)
        .help("藍色人工值疊加於考場分數條：超過時延伸，不超過時以刻痕標記。")
    }
}

/// 人工協作加評表單：組合＋判定＋備註，寫入獨立人工協作 store。
struct HumanCollabRatingEditor: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let onDone: () -> Void
    @State private var comboLabel: String = ""
    @State private var verdict: String = "勝"
    @State private var note: String = ""

    private var deltaDirection: String {
        switch verdict {
        case "勝": "positive"
        case "負": "negative"
        default: "flat"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("人工協作評分")
                .font(.system(size: 12, weight: .black, design: .rounded))
            TextField("組合（例：fable-5主審＋gpt-5.5 loops）", text: $comboLabel)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            Picker("判定", selection: $verdict) {
                Text("勝").tag("勝")
                Text("持平").tag("持平")
                Text("負").tag("負")
            }
            .pickerStyle(.segmented)
            TextField("備註（可空）", text: $note)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            HStack {
                Spacer()
                Button("儲存") {
                    let stamp = ISO8601DateFormatter().string(from: Date())
                    _ = try? TatwoHumanCollabRatingStore.default().upsert(
                        TatwoHumanCollabRatingV1(
                            id: "human-\(stamp)-\(comboLabel.hashValue)",
                            comboLabel: comboLabel.isEmpty ? "未命名組合" : comboLabel,
                            verdict: verdict,
                            deltaDirection: deltaDirection,
                            note: note,
                            ratedAt: stamp))
                    onDone()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: 23)
                .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusChip)
                .controlSize(.small)
                .disabled(comboLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}

struct TraitEvidenceOverviewBoard: View {
    let models: [TraitEvidenceDisplayModel]
    @Binding var selectedID: String
    let webEvidenceByModelSlug: [String: TatwoWebArenaModelEvidence]
    let threeDEvidenceByModelSlug: [String: Tatwo3DModelingArenaModelEvidence]
    let dimensions: [TraitEvaluationDimension]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("模型")
                    .frame(width: 108, alignment: .leading)
                Text("Web Arena（三題）")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("3D建模")
                    .frame(width: 96, alignment: .leading)
                Text("人工評分")
                    .frame(width: 70, alignment: .trailing)
            }
            .font(.system(size: 8.4, weight: .black, design: .rounded))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)

            VStack(spacing: 5) {
                ForEach(models) { model in
                    Button {
                        selectedID = model.id
                    } label: {
                        TraitEvidenceOverviewRow(
                            model: model,
                            webEvidence: webEvidenceByModelSlug[model.id],
                            threeDEvidence: threeDEvidenceByModelSlug[model.id],
                            dimensions: dimensions,
                            isSelected: selectedID == model.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

struct TraitEvidenceOverviewRow: View {
    let model: TraitEvidenceDisplayModel
    let webEvidence: TatwoWebArenaModelEvidence?
    let threeDEvidence: Tatwo3DModelingArenaModelEvidence?
    let dimensions: [TraitEvaluationDimension]
    let isSelected: Bool

    private var combinedTraitCount: Int {
        (webEvidence?.traitDimensionEvidence.count ?? 0) + (threeDEvidence?.traitDimensionEvidence.count ?? 0)
    }

    private var rowColor: Color {
        if isSelected { return .blue }
        if webEvidence != nil || threeDEvidence != nil { return .teal }
        return .gray
    }

    private var webText: String {
        guard let webEvidence else { return "Web 待測試" }
        let parts = webEvidence.caseEvidence.map { item in
            "\(Self.webShortTitle(item.title)) \(item.score)/100"
        }
        return ([webEvidence.examScoreSummaryLabel] + parts).joined(separator: " · ")
    }

    private var webColor: Color {
        webEvidence == nil ? .gray : .teal
    }

    private var threeDText: String {
        guard let threeDEvidence else { return "3D建模 待測試" }
        if let official = threeDEvidence.caseEvidence.first(where: { $0.official }) {
            let score = official.score0To100.map { "\($0)/100" } ?? "考試分數缺"
            return "official \(score) · \(official.status)"
        }
        return threeDEvidence.scoreStatusLabel
    }

    private var threeDColor: Color {
        guard let threeDEvidence else { return .gray }
        if (threeDEvidence.canonicalScore0To100 ?? -1) <= 0 { return .red }
        return threeDEvidence.status == "passed" ? .green : .purple
    }

    private var manualText: String {
        guard webEvidence != nil || threeDEvidence != nil else { return "待測試" }
        return combinedTraitCount == 0 ? "+人工" : "證據 \(combinedTraitCount)/\(dimensions.count)"
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName)
                    .font(.system(size: 10.2, weight: .black, design: .rounded))
                    .lineLimit(1)
                Text(model.subtitle)
                    .font(.system(size: 7.2, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 108, alignment: .leading)

            Text(webText)
                .font(.system(size: 9, weight: .black, design: .rounded))
                .foregroundStyle(webColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(threeDText)
                .font(.system(size: 9, weight: .black, design: .rounded))
                .foregroundStyle(threeDColor)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .frame(width: 96, alignment: .leading)

            Text(manualText)
                .font(.system(size: 10, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(rowColor)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            isSelected ? AnyShapeStyle(rowColor.opacity(0.13)) : AnyShapeStyle(Color.white.opacity(0.04)),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(isSelected ? rowColor.opacity(0.3) : Color.white.opacity(0.07), lineWidth: 1))
        .contentShape(Rectangle())
        .help("點選查看 \(model.displayName) 的考試分數與人工評分狀態")
    }

    private static func webShortTitle(_ title: String) -> String {
        if title.localizedCaseInsensitiveContains("刺青") { return "刺青" }
        if title.localizedCaseInsensitiveContains("Pionex") { return "Pionex" }
        if title.localizedCaseInsensitiveContains("3D") { return "3D網頁" }
        return String(title.prefix(5))
    }
}

struct WebArenaEvidenceTile: View {
    let model: TraitEvidenceDisplayModel
    let webEvidence: TatwoWebArenaModelEvidence?
    let threeDEvidence: Tatwo3DModelingArenaModelEvidence?
    let dimensions: [TraitEvaluationDimension]

    private var hasAnySandboxEvidence: Bool {
        webEvidence != nil || threeDEvidence != nil
    }

    private var importedTraitEvidence: [TatwoWebArenaTraitDimensionEvidence] {
        (webEvidence?.traitDimensionEvidence ?? []) + (threeDEvidence?.traitDimensionEvidence ?? [])
    }

    private var statusColor: Color {
        guard hasAnySandboxEvidence else { return .gray }
        if resolvedTraitEvidenceByDimensionID.isEmpty { return .orange }
        let allPassed = [webEvidence?.status, threeDEvidence?.status].compactMap { $0 }.allSatisfy { $0 == "passed" }
        return allPassed ? .green : .orange
    }

    private var traitCountText: String {
        guard hasAnySandboxEvidence else { return "尚無考試紀錄" }
        let arenaCount = resolvedTraitEvidenceByDimensionID.values.filter { !$0.isManualOverride }.count
        let manualCount = resolvedTraitEvidenceByDimensionID.values.filter(\.isManualOverride).count
        if arenaCount + manualCount == 0 {
            return "未考"
        }
        return "考場 \(arenaCount) 項 · 人工 \(manualCount) 項"
    }

    private var examScoreText: String {
        let labels = [
            webEvidence?.examScoreSummaryLabel,
            threeDEvidence?.examScoreSummaryLabel,
        ].compactMap { $0 }
        return labels.isEmpty ? "尚無沙盒考分" : labels.joined(separator: "；")
    }

    private var runSubtitle: String {
        switch (webEvidence, threeDEvidence) {
        case let (web?, threeD?):
            return "\(web.arena) + \(threeD.arena) · \(max(web.testedAt, threeD.testedAt))"
        case let (web?, nil):
            return "\(web.arena) · \(web.testedAt)"
        case let (nil, threeD?):
            return "\(threeD.arena) · \(threeD.testedAt)"
        case (nil, nil):
            return "尚無 sandbox receipt"
        }
    }

    private var resolvedTraitEvidenceByDimensionID: [String: TraitDimensionEvidenceResolution] {
        var resolved: [String: TraitDimensionEvidenceResolution] = [:]
        let arenaDerived = webEvidence.map(TatwoWebArenaTraitMappingCatalog.derivedEvidence(from:)) ?? []
        let arenaImported = importedTraitEvidence.filter { !Self.isManualEvidence($0) }
        for item in arenaDerived + arenaImported {
            resolved[item.dimensionID] = TraitDimensionEvidenceResolution(item: item, sourceKind: .arena)
        }
        for item in importedTraitEvidence where Self.isManualEvidence(item) {
            resolved[item.dimensionID] = TraitDimensionEvidenceResolution(item: item, sourceKind: .manual)
        }
        return resolved
    }

    private var statusLabel: String {
        guard hasAnySandboxEvidence else { return "未測試" }
        return resolvedTraitEvidenceByDimensionID.isEmpty ? "未考" : "考場映射"
    }

    private var sandboxLabel: String? {
        let labels = [
            webEvidence.map { "\($0.arena) · \($0.runID)" },
            threeDEvidence.map { "\($0.arena) · \($0.runID)" },
        ].compactMap { $0 }
        return labels.isEmpty ? nil : labels.joined(separator: "；")
    }

    private var routingText: String {
        [
            webEvidence?.routingImplication,
            threeDEvidence?.routingImplication,
            webEvidence == nil && threeDEvidence == nil ? model.subtitle : nil,
        ].compactMap { $0 }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.system(size: 12.5, weight: .black, design: .rounded))
                    Text(runSubtitle)
                        .font(.system(size: 8.8, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(examScoreText)
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.66)
                    Text(traitCountText)
                        .font(.system(size: 7.8, weight: .black, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 6)], alignment: .leading, spacing: 6) {
                if let webEvidence {
                    MiniStatusCapsule(text: webEvidence.examScoreSummaryLabel, color: .teal)
                }
                if let threeDEvidence {
                    MiniStatusCapsule(text: threeDEvidence.examScoreSummaryLabel, color: .gray)
                }
                MiniStatusCapsule(text: statusLabel, color: statusColor)
                if let webEvidence {
                    MiniStatusCapsule(text: "web sealed \(webEvidence.sealVerifiedReportCount)/\(webEvidence.reportCount)", color: .teal)
                    MiniStatusCapsule(text: webEvidence.dispatchComplete ? "web dispatch ok" : "web partial", color: webEvidence.dispatchComplete ? .green : .orange)
                } else {
                    MiniStatusCapsule(text: "Web 待測試", color: .gray)
                }
                MiniStatusCapsule(text: threeDEvidence?.scoreStatusLabel ?? "3D建模 待測試", color: .gray)
            }

            ModelArenaCoverageStrip(webEvidence: webEvidence, threeDEvidence: threeDEvidence)

            VStack(alignment: .leading, spacing: 5) {
                EmptyView()
                Text(routingText)
                    .font(.system(size: 9.2, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 7) {
                ForEach(Array(dimensions.enumerated()), id: \.element.id) { index, dimension in
                    TraitDimensionEvidenceRow(
                        index: index + 1,
                        dimension: dimension,
                        resolution: resolvedTraitEvidenceByDimensionID[dimension.id],
                        hasSandboxEvidence: hasAnySandboxEvidence,
                        sandboxLabel: sandboxLabel
                    )
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(statusColor.opacity(0.18), lineWidth: 1))
        .help(sandboxLabel ?? "\(model.displayName)：待測試")
    }

    private static func isManualEvidence(_ item: TatwoWebArenaTraitDimensionEvidence) -> Bool {
        let source = item.evidenceSource.lowercased()
        return source.contains("human") || source.contains("manual") || source.contains("人工")
    }
}

enum TraitDimensionEvidenceSourceKind {
    case manual
    case arena
}

struct TraitDimensionEvidenceResolution {
    let item: TatwoWebArenaTraitDimensionEvidence
    let sourceKind: TraitDimensionEvidenceSourceKind

    var isManualOverride: Bool { sourceKind == .manual }

    var sourceBadge: String {
        switch sourceKind {
        case .manual:
            return "人工"
        case .arena:
            if item.evidenceSource.localizedCaseInsensitiveContains("Blender") { return "3D考場" }
            return "考場"
        }
    }
}

struct ModelArenaCoverageStrip: View {
    let webEvidence: TatwoWebArenaModelEvidence?
    let threeDEvidence: Tatwo3DModelingArenaModelEvidence?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ArenaCoverageBlock(
                title: "Web",
                status: webEvidence == nil ? "待測試" : webStatusText,
                color: webEvidence == nil ? .gray : .teal,
                details: webDetails
            )
            ArenaCoverageBlock(
                title: "3D建模",
                status: threeDEvidence?.scoreStatusLabel ?? "待測試",
                color: threeDEvidence == nil ? .gray : .purple,
                details: threeDDetails
            )
        }
    }

    private var webStatusText: String {
        guard let webEvidence else { return "待測試" }
        return "\(webEvidence.reportCount)題 · \(webEvidence.status)"
    }

    private var webDetails: [String] {
        guard let webEvidence else { return ["刺青 / 3D資產網頁 / Pionex-style 尚未跑"] }
        return webEvidence.caseEvidence.map { "\($0.title) \($0.score)/100" }
    }

    private var threeDDetails: [String] {
        guard let threeDEvidence else { return ["Blender / UE5.8 / MMD 角色：待測試"] }
        return threeDEvidence.caseEvidence.map { item in
            let score = item.score0To100.map { "\($0)/100" } ?? "考試分數缺"
            let tag = item.official ? "正式" : "輔助"
            return "\(tag) \(item.title) \(score)"
        }
    }
}

struct ArenaCoverageBlock: View {
    let title: String
    let status: String
    let color: Color
    let details: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 9.4, weight: .black, design: .rounded))
                Spacer(minLength: 4)
                Text(status)
                    .font(.system(size: 8.2, weight: .black, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
            ForEach(details.prefix(3), id: \.self) { detail in
                Text(detail)
                    .font(.system(size: 8.1, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.075), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.16), lineWidth: 1))
    }
}

struct TraitDimensionEvidenceRow: View {
    let index: Int
    let dimension: TraitEvaluationDimension
    let resolution: TraitDimensionEvidenceResolution?
    let hasSandboxEvidence: Bool
    let sandboxLabel: String?

    private var item: TatwoWebArenaTraitDimensionEvidence? {
        resolution?.item
    }

    private var value: Double? {
        item.map { min(10, max(0, $0.value0To10)) }
    }

    private var color: Color {
        guard let value else { return .gray }
        if value >= 8 { return .blue }
        if value >= 6 { return .teal }
        if value >= 4 { return .orange }
        return .red
    }

    private var title: String {
        "\(index). \(dimension.title)"
    }

    private var scoreLabel: String {
        guard let value else { return "未考" }
        return String(format: "%.1f/10", value)
    }

    private var statusLabel: String {
        guard let resolution else { return "未考" }
        return resolution.isManualOverride ? item?.status ?? "人工" : "+人工評分"
    }

    private var detailText: String {
        guard let item else {
            if hasSandboxEvidence {
                return "已完成 \(sandboxLabel ?? "sandbox")；此特質目前沒有對應考場收據，標為未考。"
            }
            return "尚無 Web Arena / Code Arena / Debug Arena / PLG Arena / 3D Arena 可用收據。"
        }
        return "\(item.evidenceSource)：\(item.note)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 9.2, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(scoreLabel)
                    .font(.system(size: 8.7, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.13), in: Capsule())
                if let resolution {
                    Text(resolution.sourceBadge)
                        .font(.system(size: 7.4, weight: .black, design: .rounded))
                        .foregroundStyle(color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(color.opacity(0.10), in: Capsule())
                }
                Spacer(minLength: 0)
                Text(statusLabel)
                    .font(.system(size: 7.6, weight: .black, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }

            UnifiedScoreBar(value: value ?? 0, color: color, height: 4.5, markerCount: 10)
                .opacity(value == nil ? 0.38 : 1)

            Text(detailText)
                .font(.system(size: 8.2, weight: .bold, design: .rounded))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.052), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}


struct MiniStatusCapsule: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 7.7, weight: .black, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }
}

struct ModelSelectOption: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
}

struct DropdownSelectButton: View {
    @Binding var selection: String
    let options: [ModelSelectOption]
    let accent: Color
    var placeholder = "未指定"

    private var selectedOption: ModelSelectOption? {
        options.first { $0.id == selection }
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    selection = option.id
                } label: {
                    Label(option.name, systemImage: option.id == selection ? "checkmark.circle.fill" : "circle")
                }
                .help(option.subtitle)
            }
        } label: {
            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedOption?.name ?? placeholder)
                        .font(.system(size: 10.2, weight: .black, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    if let subtitle = selectedOption?.subtitle, subtitle.isEmpty == false {
                        Text(subtitle)
                            .font(.system(size: 8.1, weight: .bold, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .black))
                    .foregroundStyle(accent)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.095), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(accent.opacity(0.18), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selectedOption?.name ?? placeholder)
    }
}

struct TraitFolderSection<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let badge: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: icon)
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: 15, weight: .black))
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 8)

                        Text(badge)
                            .font(.system(size: 8.5, weight: .black, design: .rounded))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.13), in: Capsule())
                            .foregroundStyle(Color.accentColor)

                        Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(isExpanded ? Color.accentColor : Color.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    content()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}



struct EmptyStateStrip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}


struct SelectedRolePill: View {
    let title: String
    let profile: ModelScoreProfile?
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .black, design: .rounded))
                .foregroundStyle(color)
            Text(profile?.name ?? "未指定")
                .font(.system(size: 9.2, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: Capsule())
    }
}

struct RoleVisualCard: View {
    let title: String
    let profile: ModelScoreProfile?
    let color: Color
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(color)
            Text(profile?.name ?? "未指定")
                .font(.caption.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(note)
                .font(.system(size: 8.4, weight: .bold, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
struct ModelScoreProfile: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let strengths: [String]
    let weaknesses: [String]
    let scores: [TraitScorePoint]

    private static let headlineIDs: Set<String> = [
        "code-architecture", "macro-architecture", "context", "aesthetics"
    ]

    init(trait: ModelTrait, dimensions: [TraitEvaluationDimension]) {
        id = trait.id
        name = trait.displayName
        subtitle = Self.traitSubtitle(for: trait.id)
        strengths = Array(trait.strengths.prefix(2))
        weaknesses = Array(trait.weaknesses.prefix(2))
        let map = Self.scoreMap(for: trait)
        scores = dimensions.enumerated().map { index, dimension in
            let center = map[dimension.id] ?? Self.fallbackScore(for: dimension.id, trait: trait)
            let confidence = Self.confidence(for: dimension.id, traitID: trait.id)
            let evidence = Self.evidenceStatus(for: dimension.id)
            return TraitScorePoint(
                id: dimension.id,
                index: index + 1,
                title: dimension.title,
                shortLabel: Self.shortLabel(for: dimension.id, fallback: dimension.title),
                value: center,
                lowerBound: max(1, center - confidence.rangePadding),
                upperBound: min(10, center + confidence.rangePadding),
                confidence: confidence,
                evidenceStatus: evidence,
                rubricTag: Self.rubricTag(for: dimension.id)
            )
        }
    }

    var headlineScores: [TraitScorePoint] {
        scores.filter { Self.headlineIDs.contains($0.id) }
    }

    private static func fallbackScore(for id: String, trait: ModelTrait) -> Int {
        let s = trait.scores
        let raw: Int
        switch id {
        case "code-architecture", "syntax-consistency", "plugin-fit": raw = s.coding
        case "macro-architecture", "reasoning-depth", "first-principles", "solo-capability": raw = s.reasoning
        case "context", "opinion-integration", "multi-model-collab": raw = s.reasoning
        case "multimodal", "aesthetics": raw = s.designSense
        case "hallucination-control", "self-correction": raw = s.reviewStrictness
        case "moral-conservatism": raw = s.reviewStrictness
        case "token-efficiency": raw = 6 - s.costRisk
        case "instruction-following", "stability": raw = 6 - s.stabilityRisk
        case "creativity": raw = max(s.designSense, s.bulkThroughput)
        case "independent-objectivity": raw = s.reviewStrictness
        case "info-forecasting": raw = s.researchFreshness
        case "writing", "tact": raw = max(s.reasoning, s.reviewStrictness)
        default: raw = s.reasoning
        }
        return min(10, max(1, raw * 2))
    }


    private static func confidence(for dimensionID: String, traitID: String) -> TraitConfidence {
        let subjective: Set<String> = [
            "aesthetics", "moral-conservatism", "creativity", "first-principles",
            "independent-objectivity", "writing", "tact", "opinion-integration"
        ]
        if subjective.contains(dimensionID) { return .low }
        if traitID == "gpt-5.5" && ["macro-architecture", "plugin-fit", "multi-model-collab"].contains(dimensionID) { return .medium }
        if traitID == "opus-5" && ["reasoning-depth", "hallucination-control", "self-correction"].contains(dimensionID) { return .medium }
        if traitID == "sonnet-5" && ["syntax-consistency", "code-architecture", "instruction-following", "multi-model-collab", "self-correction"].contains(dimensionID) { return .medium }
        if traitID == "minimax-m3" && ["token-efficiency", "creativity", "stability"].contains(dimensionID) { return .medium }
        if traitID == "grok-build" && ["info-forecasting", "independent-objectivity", "creativity"].contains(dimensionID) { return .medium }
        if traitID == "fable-5" && ["reasoning-depth", "code-architecture", "hallucination-control"].contains(dimensionID) { return .provisional }
        return .provisional
    }

    private static func evidenceStatus(for dimensionID: String) -> TraitEvidenceStatus {
        switch dimensionID {
        case "syntax-consistency", "instruction-following", "token-efficiency", "stability", "hallucination-control":
            return .insufficient
        case "aesthetics", "moral-conservatism", "creativity", "independent-objectivity", "tact", "writing", "first-principles":
            return .biasReview
        case "multi-model-collab", "plugin-fit", "info-forecasting":
            return .pending
        default:
            return .estimated
        }
    }

    private static func rubricTag(for dimensionID: String) -> String {
        switch dimensionID {
        case "syntax-consistency", "instruction-following", "token-efficiency", "stability", "hallucination-control", "context", "solo-capability":
            return "可測"
        case "aesthetics", "moral-conservatism", "creativity", "first-principles", "independent-objectivity", "writing", "tact":
            return "主觀/雙評"
        default:
            return "混合"
        }
    }

    private static func shortLabel(for id: String, fallback: String) -> String {
        switch id {
        case "code-architecture": "架構"
        case "syntax-consistency": "語法"
        case "macro-architecture": "宏觀"
        case "context": "上下文"
        case "multimodal": "多模"
        case "hallucination-control": "幻覺"
        case "moral-conservatism": "保守"
        case "aesthetics": "美感"
        case "token-efficiency": "Token"
        case "reasoning-depth": "推理"
        case "instruction-following": "指令"
        case "creativity": "創造"
        case "self-correction": "修正"
        case "stability": "穩定"
        case "opinion-integration": "整合"
        case "first-principles": "本質"
        case "independent-objectivity": "客觀"
        case "plugin-fit": "插件"
        case "multi-model-collab": "協作"
        case "solo-capability": "單打"
        case "info-forecasting": "預判"
        case "writing": "文筆"
        case "tact": "圓融"
        default: String(fallback.prefix(3))
        }
    }

    private static func traitSubtitle(for id: String) -> String {
        switch id {
        case "fable-5": "暫不可用 / 只保留評級 / 不進協作"
        case "gpt-5.5": "主導 / 收斂 / Codex host intent"
        case "opus-5": "監督 / 驗收 / 高風險 judge"
        case "sonnet-5": "工程副審 / 代碼一致 / M-L Debug"
        case "minimax-m3": "大量 sub / 草稿 / checklist"
        case "grok-build": "消息 / 反例 / 客觀堅持"
        case "chatgpt-pro-mcp": "Pro 研究 / 長 memo / 反方審稿"
        case "local-qwen-ollama": "私密初掃 / 低成本預處理"
        default: "模型特質模板"
        }
    }

    private static func scoreMap(for trait: ModelTrait) -> [String: Int] {
        switch trait.id {
        case "fable-5": return [
            "code-architecture": 9, "syntax-consistency": 9, "macro-architecture": 9, "context": 9,
            "multimodal": 7, "hallucination-control": 9, "moral-conservatism": 9, "aesthetics": 7,
            "token-efficiency": 4, "reasoning-depth": 10, "instruction-following": 9, "creativity": 7,
            "self-correction": 8, "stability": 3, "opinion-integration": 8, "first-principles": 9,
            "independent-objectivity": 8, "plugin-fit": 4, "multi-model-collab": 6, "solo-capability": 9,
            "info-forecasting": 5, "writing": 9, "tact": 8]
        case "gpt-5.5": return [
            "code-architecture": 9, "syntax-consistency": 8, "macro-architecture": 10, "context": 9,
            "multimodal": 8, "hallucination-control": 8, "moral-conservatism": 8, "aesthetics": 6,
            "token-efficiency": 5, "reasoning-depth": 9, "instruction-following": 9, "creativity": 7,
            "self-correction": 7, "stability": 8, "opinion-integration": 9, "first-principles": 8,
            "independent-objectivity": 7, "plugin-fit": 10, "multi-model-collab": 9, "solo-capability": 9,
            "info-forecasting": 7, "writing": 8, "tact": 8]
        case "opus-5": return [
            "code-architecture": 8, "syntax-consistency": 8, "macro-architecture": 9, "context": 10,
            "multimodal": 7, "hallucination-control": 9, "moral-conservatism": 9, "aesthetics": 8,
            "token-efficiency": 3, "reasoning-depth": 10, "instruction-following": 8, "creativity": 7,
            "self-correction": 8, "stability": 7, "opinion-integration": 8, "first-principles": 9,
            "independent-objectivity": 8, "plugin-fit": 6, "multi-model-collab": 8, "solo-capability": 8,
            "info-forecasting": 7, "writing": 9, "tact": 8]
        case "sonnet-5": return [
            "code-architecture": 9, "syntax-consistency": 9, "macro-architecture": 9, "context": 9,
            "multimodal": 7, "hallucination-control": 8, "moral-conservatism": 8, "aesthetics": 7,
            "token-efficiency": 5, "reasoning-depth": 9, "instruction-following": 9, "creativity": 7,
            "self-correction": 8, "stability": 8, "opinion-integration": 8, "first-principles": 8,
            "independent-objectivity": 8, "plugin-fit": 8, "multi-model-collab": 9, "solo-capability": 8,
            "info-forecasting": 6, "writing": 8, "tact": 8]
        case "minimax-m3": return [
            "code-architecture": 6, "syntax-consistency": 7, "macro-architecture": 5, "context": 6,
            "multimodal": 5, "hallucination-control": 5, "moral-conservatism": 5, "aesthetics": 6,
            "token-efficiency": 9, "reasoning-depth": 5, "instruction-following": 7, "creativity": 8,
            "self-correction": 4, "stability": 7, "opinion-integration": 5, "first-principles": 5,
            "independent-objectivity": 6, "plugin-fit": 5, "multi-model-collab": 7, "solo-capability": 5,
            "info-forecasting": 5, "writing": 7, "tact": 6]
        case "grok-build": return [
            "code-architecture": 6, "syntax-consistency": 6, "macro-architecture": 7, "context": 7,
            "multimodal": 7, "hallucination-control": 6, "moral-conservatism": 4, "aesthetics": 6,
            "token-efficiency": 7, "reasoning-depth": 8, "instruction-following": 7, "creativity": 8,
            "self-correction": 6, "stability": 6, "opinion-integration": 7, "first-principles": 7,
            "independent-objectivity": 9, "plugin-fit": 5, "multi-model-collab": 7, "solo-capability": 7,
            "info-forecasting": 9, "writing": 7, "tact": 5]
        case "chatgpt-pro-mcp": return [
            "code-architecture": 6, "syntax-consistency": 7, "macro-architecture": 9, "context": 10,
            "multimodal": 8, "hallucination-control": 8, "moral-conservatism": 8, "aesthetics": 7,
            "token-efficiency": 5, "reasoning-depth": 9, "instruction-following": 8, "creativity": 8,
            "self-correction": 7, "stability": 6, "opinion-integration": 9, "first-principles": 8,
            "independent-objectivity": 7, "plugin-fit": 4, "multi-model-collab": 9, "solo-capability": 7,
            "info-forecasting": 9, "writing": 9, "tact": 9]
        case "local-qwen-ollama": return [
            "code-architecture": 4, "syntax-consistency": 5, "macro-architecture": 4, "context": 4,
            "multimodal": 3, "hallucination-control": 4, "moral-conservatism": 5, "aesthetics": 4,
            "token-efficiency": 10, "reasoning-depth": 4, "instruction-following": 6, "creativity": 5,
            "self-correction": 4, "stability": 7, "opinion-integration": 4, "first-principles": 4,
            "independent-objectivity": 5, "plugin-fit": 3, "multi-model-collab": 5, "solo-capability": 4,
            "info-forecasting": 3, "writing": 5, "tact": 5]
        default:
            return [:]
        }
    }
}

enum TraitConfidence {
    case medium
    case provisional
    case low

    var label: String {
        switch self {
        case .medium: "中"
        case .provisional: "暫"
        case .low: "低"
        }
    }

    var rangePadding: Int {
        switch self {
        case .medium: 1
        case .provisional: 2
        case .low: 2
        }
    }

    var color: Color {
        switch self {
        case .medium: .teal
        case .provisional: .orange
        case .low: .gray
        }
    }
}

enum TraitEvidenceStatus {
    case estimated
    case insufficient
    case pending
    case biasReview

    var label: String {
        switch self {
        case .estimated: "僅推測"
        case .insufficient: "樣本不足"
        case .pending: "待測"
        case .biasReview: "需偏差審核"
        }
    }

    var color: Color {
        switch self {
        case .estimated: .secondary
        case .insufficient: .orange
        case .pending: .blue
        case .biasReview: .purple
        }
    }
}

struct TraitScorePoint: Identifiable {
    let id: String
    let index: Int
    let title: String
    let shortLabel: String
    let value: Int
    let lowerBound: Int
    let upperBound: Int
    let confidence: TraitConfidence
    let evidenceStatus: TraitEvidenceStatus
    let rubricTag: String

    var rangeLabel: String {
        lowerBound == upperBound ? "\(value)" : "\(lowerBound)–\(upperBound)"
    }
}

struct TraitSummaryStack: View {
    let strengths: [String]
    let weaknesses: [String]

    var body: some View {
        HStack(spacing: 6) {
            TraitSummaryCompactPill(
                title: "優點",
                icon: "checkmark.seal.fill",
                color: .green,
                text: strengths.prefix(2).joined(separator: " / ")
            )
            TraitSummaryCompactPill(
                title: "短板",
                icon: "exclamationmark.triangle.fill",
                color: .orange,
                text: weaknesses.prefix(2).joined(separator: " / ")
            )
        }
    }
}

struct TraitSummaryCompactPill: View {
    let title: String
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Label(title, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 8.6, weight: .black, design: .rounded))
                .foregroundStyle(color)
                .frame(width: 42, alignment: .leading)
            Text(text.isEmpty ? "待補樣本" : text)
                .font(.system(size: 8.6, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
struct HorizontalScoreList: View {
    let scores: [TraitScorePoint]
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 8 : 9) {
            ForEach(scores) { score in
                HorizontalScoreRow(score: score, compact: compact)
            }
        }
    }
}

struct HorizontalScoreRow: View {
    let score: TraitScorePoint
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(compact ? score.shortLabel : "\(score.index). \(score.title)")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(compact ? .secondary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text("約 \(score.value)/10")
                    .font(.system(size: compact ? 9 : 9.5, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(scoreColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(scoreColor.opacity(0.12), in: Capsule())

                if compact == false {
                    Text("範圍 \(score.rangeLabel)")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if compact == false {
                    TraitEvidencePill(status: score.evidenceStatus)
                }
            }

            TraitSingleProgressBar(score: score, color: scoreColor, showRange: compact == false)
                .frame(height: compact ? 4.5 : 5.5)

            if compact == false {
                HStack(spacing: 6) {
                    Text("信心 \(score.confidence.label)")
                    Text("·")
                    Text(score.rubricTag)
                    Text("· 分數為估計，驗收需樣本")
                }
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, compact ? 0 : 8)
        .padding(.vertical, compact ? 0 : 7)
        .background {
            if compact == false {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.035))
            }
        }
        .help("\(score.index). \(score.title)：約 \(score.value)/10；估計範圍 \(score.rangeLabel)；\(score.evidenceStatus.label)，信心 \(score.confidence.label)")
        .accessibilityLabel("\(score.title) about \(score.value) out of 10, estimated range \(score.rangeLabel)")
    }

    private var scoreColor: Color {
        if score.value >= 8 { return .blue }
        if score.value >= 6 { return .teal }
        if score.value >= 4 { return .orange }
        return .red
    }
}

struct UnifiedScoreBar: View {
    let value: Double
    var baseValue: Double?
    var range: ClosedRange<Double>?
    let color: Color
    var deltaColor: Color?
    var height: CGFloat = 5
    var markerCount: Int = 0

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let valueX = x(for: value, width: width)
            let baseX = baseValue.map { x(for: $0, width: width) }
            let rangeLowerX = range.map { x(for: $0.lowerBound, width: width) } ?? 0
            let rangeUpperX = range.map { x(for: $0.upperBound, width: width) } ?? 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.075))

                if range != nil {
                    Capsule()
                        .fill(color.opacity(0.16))
                        .frame(width: max(5, rangeUpperX - rangeLowerX))
                        .offset(x: rangeLowerX)
                        .accessibilityHidden(true)
                }

                if let baseX {
                    Capsule()
                        .fill(color.opacity(0.72))
                        .frame(width: max(5, baseX))
                    if value >= (baseValue ?? 0) {
                        Capsule()
                            .fill((deltaColor ?? .green).opacity(0.9))
                            .frame(width: max(4, valueX - baseX))
                            .offset(x: baseX)
                    } else {
                        Capsule()
                            .fill((deltaColor ?? .red).opacity(0.82))
                            .frame(width: max(4, baseX - valueX))
                            .offset(x: valueX)
                    }
                } else {
                    Capsule()
                        .fill(color.opacity(0.86))
                        .frame(width: max(5, valueX))
                }

                if markerCount > 0 {
                    HStack(spacing: 0) {
                        ForEach(0..<markerCount, id: \.self) { index in
                            Rectangle()
                                .fill(index == 0 ? Color.clear : Color.white.opacity(0.14))
                                .frame(width: 1)
                                .frame(maxHeight: .infinity)
                            Spacer(minLength: 0)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height, alignment: .top)
    }

    private func x(for value: Double, width: CGFloat) -> CGFloat {
        let clipped = min(10.0, max(0.0, value))
        return width * CGFloat(clipped / 10.0)
    }
}

struct TraitSingleProgressBar: View {
    let score: TraitScorePoint
    let color: Color
    let showRange: Bool

    var body: some View {
        UnifiedScoreBar(
            value: Double(score.value),
            range: showRange ? Double(score.lowerBound)...Double(score.upperBound) : nil,
            color: color,
            height: showRange ? 5.5 : 4.5,
            markerCount: showRange ? 10 : 0
        )
    }
}


struct TraitEvidencePill: View {
    let status: TraitEvidenceStatus

    var body: some View {
        Text(status.label)
            .font(.system(size: 8.5, weight: .black, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.68)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(status.color.opacity(0.13), in: Capsule())
            .foregroundStyle(status.color)
    }
}

struct PairScoreTrack: View {
    let score: Double
    let color: Color

    var body: some View {
        UnifiedScoreBar(value: score, color: color, height: 4.5)
    }
}

struct CollaborationBonusSource: Identifiable {
    let id: String
    let modelName: String
    let points: Double
    let roleTitle: String
    let reason: String
}

struct CollaborationBoostProfile: Identifiable {
    let id: String
    let title: String
    let primaryName: String
    let primaryScore: Double
    let partnerName: String
    let partnerScore: Double
    let overflow: Double
    let reason: String
    let bonusSources: [CollaborationBonusSource]

    var strongerScore: Double { max(primaryScore, partnerScore) }
    var weakerScore: Double { min(primaryScore, partnerScore) }
    var final: Double { min(10, max(0, strongerScore + overflow)) }
    var primaryIsStronger: Bool { primaryScore >= partnerScore }
    var strongerName: String { primaryIsStronger ? primaryName : partnerName }
    var weakerName: String { primaryIsStronger ? partnerName : primaryName }
    var scoreGap: Double { abs(primaryScore - partnerScore) }
    var deltaColor: Color { overflow >= 0 ? .green : .red }
    var deltaSummary: String {
        if overflow >= 0 {
            return "協作加分 +\(Self.decimalLabel(abs(overflow)))"
        }
        return "協作拖累 -\(Self.decimalLabel(abs(overflow)))"
    }
    var primaryRoleLabel: String { "主導：\(primaryName)" }
    var finalRangeLabel: String { Self.rangeLabel(for: final) }

    func rangeLabel(for score: Double) -> String {
        Self.rangeLabel(for: score)
    }

    func scoreLabel(for score: Double) -> String {
        Self.decimalLabel(score)
    }

    func contributionLabel(for points: Double) -> String {
        let sign = points >= 0 ? "+" : "-"
        return "\(sign)\(Self.decimalLabel(abs(points)))"
    }

    private static func rangeLabel(for score: Double) -> String {
        let lower = max(1, Int(floor(score)))
        let upper = min(10, max(lower, Int(ceil(score))))
        return lower == upper ? "約 \(lower)" : "約 \(lower)–\(upper)"
    }

    private static func decimalLabel(_ value: Double) -> String {
        let rounded = round(value)
        if abs(value - rounded) < 0.05 {
            return "\(Int(rounded))"
        }
        return String(format: "%.1f", value)
    }
}

struct CollaborationBoostGroup: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let rows: [CollaborationBoostProfile]

    static let defaults: [CollaborationBoostGroup] = [
        .init(
            id: "gpt-lead",
            title: "GPT-5.5 主導",
            subtitle: "執行 / 收斂",
            rows: [
                .init(
                    id: "gpt-opus", title: "GPT-5.5 主導 × Opus 5",
                    primaryName: "GPT-5.5", primaryScore: 8.4,
                    partnerName: "Opus 5", partnerScore: 8.5,
                    overflow: 1.1,
                    reason: "主導收斂 + 嚴格驗收",
                    bonusSources: [
                        .init(id: "gpt", modelName: "GPT-5.5", points: 0.4, roleTitle: "主導收斂", reason: "整理方向與落地邊界"),
                        .init(id: "opus", modelName: "Opus 5", points: 0.7, roleTitle: "嚴格驗收", reason: "抓高風險盲點")
                    ]
                ),
                .init(
                    id: "gpt-sonnet", title: "GPT-5.5 主導 × Sonnet 5",
                    primaryName: "GPT-5.5", primaryScore: 8.4,
                    partnerName: "Sonnet 5", partnerScore: 8.6,
                    overflow: 1.0,
                    reason: "宏觀架構 + 工程副審",
                    bonusSources: [
                        .init(id: "gpt", modelName: "GPT-5.5", points: 0.4, roleTitle: "架構定界", reason: "定義架構與完工邊界"),
                        .init(id: "sonnet", modelName: "Sonnet 5", points: 0.6, roleTitle: "工程副審", reason: "語法一致、漏測與修補審稿")
                    ]
                ),
                .init(
                    id: "gpt-minimax", title: "GPT-5.5 主導 × MiniMax M3",
                    primaryName: "GPT-5.5", primaryScore: 8.4,
                    partnerName: "MiniMax M3", partnerScore: 6.2,
                    overflow: 0.9,
                    reason: "主導 + sub 草稿",
                    bonusSources: [
                        .init(id: "gpt", modelName: "GPT-5.5", points: 0.5, roleTitle: "挑選合併", reason: "避免草稿跑偏"),
                        .init(id: "minimax", modelName: "MiniMax M3", points: 0.4, roleTitle: "大量草稿", reason: "候選方案與 checklist")
                    ]
                ),
                .init(
                    id: "gpt-grok", title: "GPT-5.5 主導 × Grok",
                    primaryName: "GPT-5.5", primaryScore: 8.4,
                    partnerName: "Grok", partnerScore: 7.0,
                    overflow: 0.8,
                    reason: "保守收斂 + 消息反例",
                    bonusSources: [
                        .init(id: "gpt", modelName: "GPT-5.5", points: 0.3, roleTitle: "決策收斂", reason: "把消息轉成決策"),
                        .init(id: "grok", modelName: "Grok", points: 0.5, roleTitle: "消息反例", reason: "外部消息與反方堅持")
                    ]
                ),
                .init(
                    id: "gpt-pro", title: "GPT-5.5 主導 × ChatGPT Pro MCP",
                    primaryName: "GPT-5.5", primaryScore: 8.4,
                    partnerName: "ChatGPT Pro MCP", partnerScore: 8.0,
                    overflow: 1.0,
                    reason: "主導 + memo 反方",
                    bonusSources: [
                        .init(id: "gpt", modelName: "GPT-5.5", points: 0.4, roleTitle: "主導收斂", reason: "落地與決策整理"),
                        .init(id: "pro", modelName: "ChatGPT Pro MCP", points: 0.6, roleTitle: "長文反方", reason: "研究 memo 與審稿")
                    ]
                )
            ]
        ),
        .init(
            id: "opus-lead",
            title: "Opus 5 主導",
            subtitle: "裁決 / 驗收",
            rows: [
                .init(
                    id: "opus-gpt", title: "Opus 5 主導 × GPT-5.5",
                    primaryName: "Opus 5", primaryScore: 8.5,
                    partnerName: "GPT-5.5", partnerScore: 8.4,
                    overflow: 1.0,
                    reason: "嚴格裁決 + Codex 落地",
                    bonusSources: [
                        .init(id: "opus", modelName: "Opus 5", points: 0.6, roleTitle: "風險裁決", reason: "先擋未驗證結論"),
                        .init(id: "gpt", modelName: "GPT-5.5", points: 0.4, roleTitle: "落地收斂", reason: "轉成 Codex 步驟")
                    ]
                ),
                .init(
                    id: "opus-sonnet", title: "Opus 5 主導 × Sonnet 5",
                    primaryName: "Opus 5", primaryScore: 8.5,
                    partnerName: "Sonnet 5", partnerScore: 8.6,
                    overflow: 1.2,
                    reason: "高風險審稿 + 代碼一致",
                    bonusSources: [
                        .init(id: "opus", modelName: "Opus 5", points: 0.6, roleTitle: "高風險審稿", reason: "抓架構與驗收盲點"),
                        .init(id: "sonnet", modelName: "Sonnet 5", points: 0.6, roleTitle: "代碼一致", reason: "補 patch、漏測與測試缺口")
                    ]
                ),
                .init(
                    id: "opus-grok", title: "Opus 5 主導 × Grok",
                    primaryName: "Opus 5", primaryScore: 8.5,
                    partnerName: "Grok", partnerScore: 7.0,
                    overflow: 0.9,
                    reason: "保守裁決 + 消息反例",
                    bonusSources: [
                        .init(id: "opus", modelName: "Opus 5", points: 0.5, roleTitle: "保守裁決", reason: "避免消息誤判"),
                        .init(id: "grok", modelName: "Grok", points: 0.4, roleTitle: "消息反例", reason: "補外部觀點")
                    ]
                ),
                .init(
                    id: "opus-minimax", title: "Opus 5 主導 × MiniMax M3",
                    primaryName: "Opus 5", primaryScore: 8.5,
                    partnerName: "MiniMax M3", partnerScore: 6.2,
                    overflow: 0.9,
                    reason: "嚴格篩選 + 大量候選",
                    bonusSources: [
                        .init(id: "opus", modelName: "Opus 5", points: 0.6, roleTitle: "嚴格篩選", reason: "淘汰假陽性草稿"),
                        .init(id: "minimax", modelName: "MiniMax M3", points: 0.3, roleTitle: "大量候選", reason: "快速列變體")
                    ]
                )
            ]
        )
    ].sorted { lhs, rhs in
        func rank(_ id: String) -> Int {
            switch id {
            case "opus-lead": return 0
            case "gpt-lead": return 1
            default: return 9
            }
        }
        return rank(lhs.id) < rank(rhs.id)
    }
}
struct CollaborationBoostRow: View {
    let row: CollaborationBoostProfile
    private let strongColor = Color.blue
    private let weakColor = Color.cyan
    private let overflowColor = Color.green

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.caption.weight(.black))
                    Text(row.primaryRoleLabel)
                        .font(.system(size: 8.2, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(row.deltaSummary)
                    .font(.caption2.monospacedDigit().weight(.black))
                    .foregroundStyle(row.deltaColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(row.deltaColor.opacity(0.12), in: Capsule())
            }

            CollaborationScoreDuel(row: row, strongColor: strongColor, weakColor: weakColor)
            CollaborationEquation(row: row, strongColor: strongColor, overflowColor: overflowColor)
            CollaborationBonusSources(row: row, strongColor: strongColor, weakColor: weakColor)
        }
        .padding(10)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Color.white.opacity(0.075), lineWidth: 1))
    }
}

struct CollaborationScoreDuel: View {
    let row: CollaborationBoostProfile
    let strongColor: Color
    let weakColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            CollaborationScoreLine(
                badge: "較強",
                name: row.strongerName,
                score: row.strongerScore,
                color: strongColor
            )
            CollaborationScoreLine(
                badge: "較弱",
                name: row.weakerName,
                score: row.weakerScore,
                color: weakColor
            )
            HStack(spacing: 5) { Badge("baseline"); Badge("lead = center") }
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }
}

struct CollaborationScoreLine: View {
    let badge: String
    let name: String
    let score: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(badge)
                    .font(.system(size: 8.3, weight: .black, design: .rounded))
                    .foregroundStyle(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.13), in: Capsule())
                Text(name)
                    .font(.caption2.weight(.black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Spacer(minLength: 8)
                Text(String(format: "%.1f", score))
                    .font(.system(size: 10, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(color)
            }
            PairScoreTrack(score: score, color: color)
        }
        .padding(8)
        .background(color.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
struct CollaborationEquation: View {
    let row: CollaborationBoostProfile
    let strongColor: Color
    let overflowColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("協作後")
                    .font(.caption2.weight(.black))
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("約 \(row.scoreLabel(for: row.final)) / 10")
                        .font(.caption.monospacedDigit().weight(.black))
                        .foregroundStyle(row.deltaColor)
                    Text("高於單體最佳")
                        .font(.system(size: 8.2, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            CollaborationDeltaTrack(
                baseline: row.strongerScore,
                overflow: row.overflow,
                final: row.final,
                strongColor: strongColor,
                positiveColor: overflowColor,
                negativeColor: .red
            )
            HStack(spacing: 9) {
                LegendDot(color: strongColor, text: "藍色：單體基準")
                LegendDot(color: row.deltaColor, text: row.overflow >= 0 ? "綠色：加分" : "紅色：拖累")
                Text("來源：\(row.bonusSources.map(\.roleTitle).joined(separator: " + "))")
                    .font(.system(size: 8.2, weight: .bold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Spacer(minLength: 0)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

struct CollaborationDeltaTrack: View {
    let baseline: Double
    let overflow: Double
    let final: Double
    let strongColor: Color
    let positiveColor: Color
    let negativeColor: Color

    var body: some View {
        UnifiedScoreBar(
            value: final,
            baseValue: baseline,
            color: strongColor,
            deltaColor: overflow >= 0 ? positiveColor : negativeColor,
            height: 5.5
        )
        .accessibilityLabel("baseline \(baseline), overflow \(overflow), final \(final)")
    }
}

struct CollaborationBonusSources: View {
    let row: CollaborationBoostProfile
    let strongColor: Color
    let weakColor: Color

    var body: some View {
        DisclosureGroup {
            VStack(spacing: 6) {
                ForEach(row.bonusSources) { source in
                    CollaborationBonusSourceChip(
                        source: source,
                        contributionText: row.contributionLabel(for: source.points),
                        roleText: source.modelName == row.strongerName ? "較強" : "互補",
                        color: source.modelName == row.strongerName ? strongColor : weakColor
                    )
                }
            }
            .padding(.top, 6)
        } label: {
            Label("加分來源：\(row.bonusSources.map(\.roleTitle).joined(separator: " + "))", systemImage: "plus.circle")
                .font(.caption2.weight(.black))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

struct CollaborationBonusSourceChip: View {
    let source: CollaborationBonusSource
    let contributionText: String
    let roleText: String
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(source.roleTitle)
                        .font(.system(size: 9.2, weight: .black, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(contributionText)
                        .font(.system(size: 8.4, weight: .black, design: .rounded).monospacedDigit())
                        .foregroundStyle(.green)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.6)
                        .background(Color.green.opacity(0.12), in: Capsule())
                }
                HStack(spacing: 4) {
                    Text(source.modelName)
                        .font(.system(size: 7.6, weight: .bold, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                    Text("·")
                        .font(.system(size: 7.2, weight: .bold, design: .rounded))
                        .foregroundStyle(.tertiary)
                    Text(source.reason)
                        .font(.system(size: 7.6, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.038), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

struct LegendDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}


struct TraitStandardTile: View {
    let index: Int
    let dimension: TraitEvaluationDimension

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index)")
                .font(.caption2.monospacedDigit().weight(.black))
                .frame(width: 22, height: 22)
                .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(dimension.title)
                    .font(.caption.weight(.black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Text(dimension.plainMeaning)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}
