import SwiftUI
import TatwoUltraworkCore

// D① 變更收據式 diff（非普通 editor clone）：逐檔看 AI 改了什麼，綁 GoalRun/reviewer/測試脈絡。
// 不盲信「已修好」——一眼看每檔加/刪、逐行對照。
struct DiffReviewView: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let diffProvider: () -> TatwoParsedDiff
    var goalLabel: String? = nil
    var reviewerLabel: String? = nil

    @State private var diff: TatwoParsedDiff = TatwoParsedDiff(files: [])
    @State private var expanded: Set<String> = []
    private func reload() { diff = diffProvider() }

    private var totalAdded: Int { diff.files.reduce(0) { $0 + $1.addedCount } }
    private var totalRemoved: Int { diff.files.reduce(0) { $0 + $1.removedCount } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if diff.files.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(diff.files, id: \.newPath) { file in
                            fileCard(file)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
        .onAppear(perform: reload)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(LiquidGlassTokens.brandAccent)
                Text("變更收據").font(.system(size: 13, weight: .black, design: .rounded))
                Spacer(minLength: 4)
                Text("+\(totalAdded)").font(.system(size: 10.5, weight: .black, design: .rounded)).foregroundStyle(.green)
                Text("−\(totalRemoved)").font(.system(size: 10.5, weight: .black, design: .rounded)).foregroundStyle(.red)
                Button(action: reload) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("重讀 git diff")
            }
            HStack(spacing: 6) {
                Text("\(diff.files.count) 檔").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                if let goalLabel { receiptChip("GoalRun", goalLabel, "target") }
                if let reviewerLabel { receiptChip("副審", reviewerLabel, "checkmark.seal") }
            }
        }
    }

    private func receiptChip(_ k: String, _ v: String, _ icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text("\(k) \(v)").font(.system(size: 8.5, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(LiquidGlassTokens.brandAccent)
        .padding(.horizontal, 6).frame(height: 16)
        .background(LiquidGlassTokens.brandAccent.opacity(0.1), in: Capsule())
    }

    private func fileCard(_ file: TatwoDiffFile) -> some View {
        let key = file.newPath.isEmpty ? file.oldPath : file.newPath
        let isOpen = expanded.contains(key)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if isOpen { expanded.remove(key) } else { expanded.insert(key) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .black)).foregroundStyle(.secondary).frame(width: 9)
                    changeBadge(file.changeKind)
                    Text(displayPath(file)).font(.system(size: 10.5, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if file.isBinary {
                        Text("binary").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    } else {
                        Text("+\(file.addedCount)").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                        Text("−\(file.removedCount)").font(.system(size: 9, weight: .bold)).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen, !file.isBinary {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                    hunkView(hunk)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(LiquidGlassTokens.brandAccent.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(LiquidGlassTokens.brandAccent.opacity(0.10), lineWidth: 1))
    }

    private func hunkView(_ hunk: TatwoDiffHunk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hunk.header)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(LiquidGlassTokens.brandAccent.opacity(0.75))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LiquidGlassTokens.brandAccent.opacity(0.05))
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                lineRow(line)
            }
        }
    }

    private func lineRow(_ line: TatwoDiffLine) -> some View {
        let bg: Color = line.kind == .added ? .green.opacity(0.10) : (line.kind == .removed ? .red.opacity(0.10) : .clear)
        let sign = line.kind == .added ? "+" : (line.kind == .removed ? "−" : " ")
        return HStack(spacing: 0) {
            Text(line.oldLineNumber.map(String.init) ?? "").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
            Text(line.newLineNumber.map(String.init) ?? "").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing).padding(.trailing, 5)
            Text(sign).font(.system(size: 9.5, weight: .bold, design: .monospaced)).foregroundStyle(line.kind == .added ? .green : (line.kind == .removed ? .red : .secondary)).frame(width: 10)
            Text(line.text).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 0.5).padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg)
    }

    private func changeBadge(_ k: TatwoDiffChangeKind) -> some View {
        let (label, color): (String, Color) = {
            switch k {
            case .added: return ("新", .green)
            case .modified: return ("改", LiquidGlassTokens.brandAccent)
            case .deleted: return ("刪", .red)
            case .renamed: return ("移", .orange)
            }
        }()
        return Text(label).font(.system(size: 8, weight: .black)).foregroundStyle(color)
            .frame(width: 15, height: 15).background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func displayPath(_ f: TatwoDiffFile) -> String {
        if f.changeKind == .renamed, f.oldPath != f.newPath { return "\(f.oldPath) → \(f.newPath)" }
        return f.newPath.isEmpty ? f.oldPath : f.newPath
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary.opacity(0.7))
            Text("工作目錄無未提交變更").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}
