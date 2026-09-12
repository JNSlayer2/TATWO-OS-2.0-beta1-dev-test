import Foundation
import SwiftUI

struct TabDesignPhilosophyContent: Equatable {
    let chat: String
    let cli: String
    let ultrawork: String

    init(markdown: String) {
        let fallback = Self.sections(from: TabDesignPhilosophyLoader.fallbackMarkdown)
        let sections = Self.sections(from: markdown)
        chat = sections["Chat"] ?? fallback["Chat"] ?? ""
        cli = sections["CLI"] ?? fallback["CLI"] ?? ""
        ultrawork = sections["Ultrawork"] ?? fallback["Ultrawork"] ?? ""
    }

    private static func sections(from markdown: String) -> [String: String] {
        let requestedSections = ["Chat", "CLI", "Ultrawork"]
        var result: [String: String] = [:]
        var activeSection: String?
        var lines: [String] = []

        func commitSection() {
            guard let activeSection else { return }
            let text = lines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                result[activeSection] = text
            }
        }

        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                commitSection()
                activeSection = requestedSections.first(where: {
                    line.hasPrefix("## \($0)")
                })
                lines = []
            } else if activeSection != nil,
                      line.trimmingCharacters(in: .whitespacesAndNewlines) != "---"
            {
                lines.append(line)
            }
        }
        commitSection()
        return result
    }
}

enum TabDesignPhilosophyLoader {
    static let resourceName = "tab-design-philosophy"
    static let resourceExtension = "md"

    static let fallbackMarkdown = """
    ## Chat
    一般聊天，也能開**專案 thread（對話串）**，用來構思、討論與迭代想法。

    **與 CLI 如何合作**：Chat thread 可接到 CLI session 繼續執行；CLI 做到一個階段，也能回到 Chat 閱讀與討論。兩者在同一專案下互相接力。

    ## CLI
    CLI 以專案下的 **session** 為單位，適合直接跑命令、實作與除錯。session 與 Chat thread 刻意區分，但能雙向交接。

    ## Ultrawork
    **設計中，先保留 placeholder。** 後續再發展成架構閉環與多面協作的觀測台。
    """

    static func loadBundledContent() -> TabDesignPhilosophyContent {
        let markdown: String
        if let url = Bundle.module.url(
            forResource: resourceName,
            withExtension: resourceExtension
        ),
        let bundledMarkdown = try? String(contentsOf: url, encoding: .utf8),
        !bundledMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            markdown = bundledMarkdown
        } else {
            markdown = fallbackMarkdown
        }

        return TabDesignPhilosophyContent(markdown: markdown)
    }
}

struct TabDesignPhilosophyPopoverView: View {
    private let content: TabDesignPhilosophyContent

    init(content: TabDesignPhilosophyContent = TabDesignPhilosophyLoader.loadBundledContent()) {
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("分頁設計說明")
                        .font(ChatTypography.systemUI(13, weight: .semibold))
                    Text("Chat rail 雛形")
                        .font(ChatTypography.systemUI(10.5, weight: .regular))
                        .foregroundStyle(.secondary)
                }

                philosophySection(
                    title: "Chat",
                    symbol: "bubble.left.and.bubble.right",
                    text: selectedParagraphs(from: content.chat, indices: [0, 1]),
                    isPrimary: true
                )

                philosophySection(
                    title: "CLI 分頁",
                    symbol: "terminal",
                    text: selectedParagraphs(
                        from: content.cli,
                        indices: [0, 1, paragraphCount(in: content.cli) - 1]
                    ),
                    isPrimary: false
                )

                philosophySection(
                    title: "Ultrawork",
                    symbol: "square.dashed",
                    text: content.ultrawork,
                    isPrimary: false
                )
            }
            .padding(14)
        }
        .frame(width: 300, height: 390)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 14, x: 0, y: 7)
    }

    private func philosophySection(
        title: String,
        symbol: String,
        text: String,
        isPrimary: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(ChatTypography.systemUI(11.5, weight: .semibold))
                .foregroundStyle(isPrimary ? .primary : .secondary)

            Text(attributedText(from: text))
                .font(ChatTypography.systemUI(11, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            Color.white.opacity(isPrimary ? 0.065 : 0.035),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(isPrimary ? 0.11 : 0.07), lineWidth: 1)
        }
    }

    private func attributedText(from markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
    }

    private func paragraphCount(in markdown: String) -> Int {
        paragraphs(in: markdown).count
    }

    private func selectedParagraphs(from markdown: String, indices: [Int]) -> String {
        let source = paragraphs(in: markdown)
        var selected: [String] = []
        for index in indices where source.indices.contains(index) {
            let paragraph = source[index]
            if !selected.contains(paragraph) {
                selected.append(paragraph)
            }
        }
        return selected.isEmpty ? markdown : selected.joined(separator: "\n\n")
    }

    private func paragraphs(in markdown: String) -> [String] {
        markdown
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
