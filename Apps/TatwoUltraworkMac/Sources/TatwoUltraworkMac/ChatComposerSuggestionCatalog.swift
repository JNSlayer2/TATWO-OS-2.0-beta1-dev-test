import Foundation
import TatwoUltraworkCore

enum ChatComposerSuggestionSelection {
    static func next(current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return 0 }
        return min(current + 1, count - 1)
    }

    static func previous(current: Int?, count: Int) -> Int? {
        guard count > 0, let current else { return nil }
        return current <= 0 ? nil : min(current - 1, count - 1)
    }
}

enum ChatComposerSkillCatalog {
    static func suggestions(
        in book: TatwoPluginRegistryBookV1,
        query: String,
        limit: Int = 6
    ) -> [PluginRegistryEntry] {
        let lowered = query.lowercased()
        let composerSkills = book.sortedEntries.filter {
            $0.kind == .skill || $0.id == "tatwo-ultrawork"
        }
        let matches = composerSkills.filter { entry in
            lowered.isEmpty
                || entry.id.lowercased().contains(lowered)
                || entry.name.lowercased().contains(lowered)
                || (entry.path ?? "").lowercased().contains(lowered)
        }
        return Array(matches.prefix(limit))
    }
}

struct ChatComposerSlashMatch: Equatable {
    let command: String
}

enum ChatComposerSlashCatalog {
    static let commands = ["/plg", "/plan", "/goal", "/issue", "/蒸餾"]

    static func matches(prompt: String) -> [ChatComposerSlashMatch] {
        let activeLine = prompt
            .split(separator: "\n", omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? prompt
        let trimmed = activeLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return [] }
        guard !trimmed.dropFirst().contains(where: \.isWhitespace) else { return [] }
        return commands
            .filter { $0.hasPrefix(trimmed) || trimmed.hasPrefix($0) }
            .map(ChatComposerSlashMatch.init(command:))
    }

    static func inserting(command: String, into prompt: String) -> String {
        let inserted = TatwoSlashCommandParser.replacingPartialCommand(
            in: prompt,
            with: command)
        return inserted.hasSuffix(" ") ? inserted : inserted + " "
    }
}
