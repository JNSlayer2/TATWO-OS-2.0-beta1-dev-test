import SwiftUI
import TatwoUltraworkCore

/// 模型顏色語彙：協作補強段、覆蓋徽章共用。人工評分固定藍色。
func traitModelColor(_ modelID: String) -> Color {
    let key = modelID.lowercased()
    if key.contains("fable") { return .orange }
    if key.contains("gpt-5.5") { return .green }
    if key.contains("gpt-5.4") { return .mint }
    if key.contains("sonnet") { return Color(red: 0.95, green: 0.72, blue: 0.2) }
    if key.contains("minimax") { return .purple }
    if key.contains("grok") { return Color(red: 0.45, green: 0.62, blue: 0.78) }
    if key.contains("haiku") { return .pink }
    if key.contains("opus") { return Color(red: 0.85, green: 0.45, blue: 0.3) }
    return .gray
}

let humanRatingColor = Color.blue

/// T5 特質卡板：分數條為王，一切說明點擊才展開；來源=評測/考場/人工/未考。
struct TraitCardsSection: View {
    @State private var cards: [TatwoModelTraitCardV1] = []
    @State private var selectedModelID: String? = nil
    @State private var humanRatings: [String: TatwoHumanTraitRatingV1] = [:]

    private var selected: TatwoModelTraitCardV1? {
        cards.first { $0.modelID == selectedModelID } ?? cards.first
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        traitCardsTitle
                        Spacer(minLength: 0)
                        traitCardsLegend
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        traitCardsTitle
                        traitCardsLegend
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if cards.isEmpty {
                    Text("還沒有任何特質卡。跑完評分考試並產卡後，這裡會出現各模型的分數條。")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(cards) { card in
                            Button {
                                withTransaction(Transaction(animation: nil)) {
                                    selectedModelID = card.modelID
                                }
                            } label: {
                                Text(card.modelID)
                                    .font(.caption2.weight(.black))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.72)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(
                                        (selected?.modelID == card.modelID
                                            ? traitModelColor(card.modelID).opacity(0.25) : Color.white.opacity(0.06)),
                                        in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let card = selected {
                        TraitCardDetail(
                            card: card,
                            humanRatings: humanRatings,
                            onRatingChanged: reloadHumanRatings)
                    }
                }
            }
        }
        .task {
            cards = TatwoModelTraitCardStore.default().allCards()
            reloadHumanRatings()
        }
    }


    private var traitCardsTitle: some View {
        HStack(spacing: 8) {
            Text("特質卡（考試實證）")
                .font(.headline.weight(.black))
                .fixedSize(horizontal: false, vertical: true)
            Badge("\(cards.count) 模型有卡")
                .layoutPriority(1)
        }
    }

    private var traitCardsLegend: some View {
        HStack(spacing: 10) {
            legendDot(.green, "評測")
            legendDot(.teal, "考場")
            legendDot(humanRatingColor, "人工")
            legendDot(.gray, "未考")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func reloadHumanRatings() {
        var map: [String: TatwoHumanTraitRatingV1] = [:]
        for rating in TatwoHumanTraitRatingStore.default().all() {
            map[rating.id] = rating
        }
        humanRatings = map
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
        }
    }
}

struct TraitCardDetail: View {
    let card: TatwoModelTraitCardV1
    let humanRatings: [String: TatwoHumanTraitRatingV1]
    let onRatingChanged: () -> Void

    @State private var showOverallNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.oneLiner)
                .font(.callout.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)

            if !card.dimensionScores.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(card.dimensionScores) { score in
                        TraitDimensionBarRow(
                            modelID: card.modelID,
                            score: score,
                            human: humanRatings["\(card.modelID)#\(score.dimensionID)"],
                            onRatingChanged: onRatingChanged)
                    }
                }
            }

            if !(card.strengths + card.weaknesses).isEmpty || !card.notes.isEmpty {
                Button {
                    showOverallNotes.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showOverallNotes ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .black))
                        Text("整體說明")
                            .font(.system(size: 11, weight: .black))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showOverallNotes {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(card.strengths) { claim in
                            ClaimDetailLine(claim: claim, positive: true)
                        }
                        ForEach(card.weaknesses) { claim in
                            ClaimDetailLine(claim: claim, positive: false)
                        }
                        if !card.notes.isEmpty {
                            Text(card.notes)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(8)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 維度細條：6pt 底條＋3pt 人工藍疊條；尾端 chevron 點擊展開該維度說明與收據。
struct TraitDimensionBarRow: View {
    let modelID: String
    let score: TatwoModelTraitDimensionScore
    let human: TatwoHumanTraitRatingV1?
    let onRatingChanged: () -> Void

    @State private var showRatingEditor = false

    private var normalizedStatus: String {
        score.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    private var isUntested: Bool { normalizedStatus == "untested" }
    private var sourceLabel: String {
        if isUntested { return "未考" }
        return normalizedStatus == "measured" ? "評測" : "考場"
    }
    private var sourceColor: Color {
        if isUntested { return .gray }
        return normalizedStatus == "measured" ? .green : .teal
    }
    private var examValue: Double? {
        isUntested ? nil : min(max(score.value0To10, 0), 10)
    }
    private var displayValue: Double? { human?.value0To10 ?? examValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(score.dimensionID)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(minWidth: 76, idealWidth: 132, maxWidth: 150, alignment: .leading)
                        .lineLimit(2)
                        .minimumScaleFactor(0.76)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(examValue.map { String(format: "%.1f", $0) } ?? "—")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(sourceColor)
                        .frame(width: 30, alignment: .trailing)

                    Text(sourceLabel)
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(sourceColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(sourceColor.opacity(0.12), in: Capsule())
                        .layoutPriority(1)

                    Button {
                        showRatingEditor = true
                    } label: {
                        Text(human != nil ? "人工 " + String(format: "%.1f", human!.value0To10) : "+人工")
                            .font(.system(size: 9, weight: .black))
                            .lineLimit(1)
                            .minimumScaleFactor(0.76)
                            .foregroundStyle(human != nil ? humanRatingColor : .secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                (human != nil ? humanRatingColor.opacity(0.12) : Color.primary.opacity(0.05)),
                                in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(1)

                    Spacer(minLength: 0)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.07))
                        if let exam = examValue {
                            LinearGradient(
                                colors: [.teal, .green],
                                startPoint: .leading, endPoint: .trailing)
                                .clipShape(Capsule())
                                .mask(alignment: .leading) {
                                    Rectangle()
                                        .frame(width: max(geo.size.width * exam / 10, 3))
                                }
                        }
                        if let human {
                            Circle()
                                .fill(humanRatingColor)
                                .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                                .frame(width: 6, height: 6)
                                .offset(x: min(
                                    max(geo.size.width * human.value0To10 / 10 - 3, 0),
                                    geo.size.width - 6))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 6)
            }
            if showRatingEditor {
                HumanRatingEditor(
                    modelID: modelID,
                    dimensionID: score.dimensionID,
                    existing: human,
                    onDone: {
                        showRatingEditor = false
                        onRatingChanged()
                    })
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

/// 展開後的說明行：一顆狀態點＋白話一句＋收據 ref。
struct ClaimDetailLine: View {
    let claim: TatwoModelTraitClaim
    let positive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(positive ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text(claim.plainClaim)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(claim.evidenceRefs, id: \.self) { ref in
                Text("收據: \(ref)")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.leading, 12)
            }
        }
    }
}

/// 人工評分：0 為基準、按住上下滑動調分（上＋下－，0.5 步進），備註＋儲存/清除。
struct HumanRatingEditor: View {
    let modelID: String
    let dimensionID: String
    let existing: TatwoHumanTraitRatingV1?
    let onDone: () -> Void

    @State private var value: Double = 0
    @State private var dragBase: Double? = nil
    @State private var note: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("人工評分 · \(dimensionID)")
                .font(.system(size: 12, weight: .black))

            HStack(spacing: 12) {
                VStack(spacing: 2) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.tertiary)
                    Text(String(format: "%.1f", value))
                        .font(.system(size: 30, weight: .black).monospacedDigit())
                        .foregroundStyle(humanRatingColor)
                        .frame(width: 86)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(humanRatingColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { g in
                            let base = dragBase ?? value
                            if dragBase == nil { dragBase = value }
                            let raw = base - Double(g.translation.height) / 16.0
                            value = min(max((raw * 2).rounded() / 2, 0), 10)
                        }
                        .onEnded { _ in dragBase = nil }
                )
                Text("按住上下滑調分")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }

            TextField("備註（可空）", text: $note)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            HStack {
                if existing != nil {
                    Button("清除評分", role: .destructive) {
                        _ = try? TatwoHumanTraitRatingStore.default()
                            .remove(modelID: modelID, dimensionID: dimensionID)
                        onDone()
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("儲存") {
                    let stamp = ISO8601DateFormatter().string(from: Date())
                    _ = try? TatwoHumanTraitRatingStore.default().upsert(
                        TatwoHumanTraitRatingV1(
                            modelID: modelID, dimensionID: dimensionID,
                            value0To10: value, ratedAt: stamp, note: note))
                    onDone()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 268)
        .onAppear {
            if let existing {
                value = existing.value0To10
                note = existing.note
            }
        }
    }
}
