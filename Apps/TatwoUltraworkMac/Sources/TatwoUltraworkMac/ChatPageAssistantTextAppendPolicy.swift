import Foundation

/// The single append primitive used by ChatPage for normalized assistant text.
///
/// This intentionally performs no content-based deduplication. Stream
/// producers must choose exactly one representation: ordered deltas or one
/// terminal payload. Silently collapsing duplicate full-text events here would
/// hide a broken JSONL producer and can also delete legitimate repeated text.
///
/// The in-flight pending row keeps an empty body and a compact-activity
/// status (`pendingInFlightStatus`) so ChatLeafViews can reuse the existing
/// breathing-text idiom. The first streamed token replaces that empty body
/// in place; later fragments concatenate.
enum ChatPageAssistantTextAppendPolicy {
    /// Status that renders the assistant-side pending placeholder via the
    /// existing `CodexActivityInlineText` breathing-text row. Keep this out of
    /// the inert `streaming` bucket so the row stays visible until the first
    /// token arrives.
    static let pendingInFlightStatus = "thinking"

    static func isPendingPlaceholderBody(_ existing: String) -> Bool {
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "…" || trimmed == "..."
    }

    static func appending(_ fragment: String, to existing: String) -> String {
        if isPendingPlaceholderBody(existing) {
            return fragment
        }
        return existing + fragment
    }
}
