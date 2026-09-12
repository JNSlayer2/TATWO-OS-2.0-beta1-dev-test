import SwiftUI
import AppKit
import Foundation
import QuickLook
import TatwoUltraworkCore

enum ChatDropPathDecoder {
    static func path(from item: NSSecureCoding?) -> String? {
        if let url = item as? URL { return url.path }
        if let data = item as? Data,
           let raw = String(data: data, encoding: .utf8),
           let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return url.path
        }
        if let string = item as? String, let url = URL(string: string) {
            return url.path
        }
        return nil
    }
}

struct TerminalLineView: View {
    let line: TatwoTerminalLine

    var body: some View {
        Text(attributedLine)
            .font(ChatTypography.terminalMono)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributedLine: AttributedString {
        var result = AttributedString()
        for span in line.spans {
            var fragment = AttributedString(span.text.isEmpty ? " " : span.text)
            fragment.foregroundColor = span.foreground.swiftUIColor
            if span.isBold {
                fragment.font = ChatTypography.terminalMono.bold()
            }
            result += fragment
        }
        return result
    }
}

private extension TatwoTerminalColor {
    var swiftUIColor: Color {
        switch self {
        case .default: return Color.green.opacity(0.92)
        case .black: return .black
        case .red: return .red
        case .green: return .green
        case .yellow: return .yellow
        case .blue: return .blue
        case .magenta: return .purple
        case .cyan: return .cyan
        case .white: return .white
        case .brightBlack: return .gray
        case .brightRed: return Color(red: 1.0, green: 0.32, blue: 0.32)
        case .brightGreen: return Color(red: 0.3, green: 1.0, blue: 0.45)
        case .brightYellow: return Color(red: 1.0, green: 0.86, blue: 0.22)
        case .brightBlue: return Color(red: 0.38, green: 0.62, blue: 1.0)
        case .brightMagenta: return Color(red: 1.0, green: 0.45, blue: 1.0)
        case .brightCyan: return Color(red: 0.35, green: 1.0, blue: 1.0)
        case .brightWhite: return .white
        }
    }
}

struct ChatMessageDerivedCacheKey: Hashable {
    let messageID: String
    let role: String
    let text: String
    let status: String?
    let textFingerprint: ChatStableContentFingerprint
    let statusFingerprint: ChatStableContentFingerprint
    let statusWasNil: Bool
    let eventKind: String
    let hasPlanQuestions: Bool
    let parserVersion: Int
    let textRevision: UUID?

    init(
        messageID: String,
        role: String,
        text: String,
        status: String?,
        textFingerprint: ChatStableContentFingerprint,
        statusFingerprint: ChatStableContentFingerprint,
        statusWasNil: Bool,
        eventKind: String,
        hasPlanQuestions: Bool,
        parserVersion: Int =
            TatwoAssistantTranscriptCache.defaultParserVersion,
        textRevision: UUID? = nil
    ) {
        self.messageID = messageID
        self.role = role
        self.text = text
        self.status = status
        self.textFingerprint = textFingerprint
        self.statusFingerprint = statusFingerprint
        self.statusWasNil = statusWasNil
        self.eventKind = eventKind
        self.hasPlanQuestions = hasPlanQuestions
        self.parserVersion = parserVersion
        self.textRevision = textRevision
    }

    static func == (
        lhs: ChatMessageDerivedCacheKey,
        rhs: ChatMessageDerivedCacheKey
    ) -> Bool {
        lhs.messageID == rhs.messageID
            && lhs.role == rhs.role
            && lhs.textFingerprint == rhs.textFingerprint
            && lhs.statusFingerprint == rhs.statusFingerprint
            && lhs.statusWasNil == rhs.statusWasNil
            && lhs.eventKind == rhs.eventKind
            && lhs.hasPlanQuestions == rhs.hasPlanQuestions
            && lhs.parserVersion == rhs.parserVersion
            && lhs.text == rhs.text
            && lhs.status == rhs.status
    }

    func hash(into hasher: inout Hasher) {
        // Fingerprints keep the hot lookup fixed-size. Exact source remains in
        // equality so a collision can only become a normal cache miss.
        hasher.combine(messageID)
        hasher.combine(role)
        hasher.combine(textFingerprint)
        hasher.combine(statusFingerprint)
        hasher.combine(statusWasNil)
        hasher.combine(eventKind)
        hasher.combine(hasPlanQuestions)
        hasher.combine(parserVersion)
    }

    var estimatedResidentBytes: Int {
        messageID.utf8.count
            + role.utf8.count
            + textFingerprint.utf8Count
            + statusFingerprint.utf8Count
            + eventKind.utf8.count
            + 192
    }

    func matchesNonTextFields(of other: Self) -> Bool {
        messageID == other.messageID
            && role == other.role
            && status == other.status
            && statusFingerprint == other.statusFingerprint
            && statusWasNil == other.statusWasNil
            && eventKind == other.eventKind
            && hasPlanQuestions == other.hasPlanQuestions
            && parserVersion == other.parserVersion
    }
}

final class ChatMessageDerivedSnapshot: Equatable {
    let transcriptDisplayText: String
    let transcriptTextView: Text
    let inlineAttachments: [ChatInlineAttachment]
    let isTranscriptNoise: Bool
    let isInertAssistantStreamingPlaceholder: Bool
    let isInertAssistantPlaceholder: Bool
    let transcriptDisplayUTF8Count: Int
    let transcriptDisplayFingerprint: ChatStableContentFingerprint
    let displayAppendBaseRevision: UUID?
    let displayAppendSuffix: String?

    init(
        transcriptDisplayText: String,
        transcriptTextView: Text,
        inlineAttachments: [ChatInlineAttachment],
        isTranscriptNoise: Bool,
        isInertAssistantStreamingPlaceholder: Bool,
        isInertAssistantPlaceholder: Bool,
        transcriptDisplayUTF8Count: Int? = nil,
        transcriptDisplayFingerprint: ChatStableContentFingerprint? = nil,
        displayAppendBaseRevision: UUID? = nil,
        displayAppendSuffix: String? = nil
    ) {
        self.transcriptDisplayText = transcriptDisplayText
        self.transcriptTextView = transcriptTextView
        self.inlineAttachments = inlineAttachments
        self.isTranscriptNoise = isTranscriptNoise
        self.isInertAssistantStreamingPlaceholder =
            isInertAssistantStreamingPlaceholder
        self.isInertAssistantPlaceholder = isInertAssistantPlaceholder
        let resolvedFingerprint =
            transcriptDisplayFingerprint
            ?? ChatStableContentFingerprint(transcriptDisplayText)
        self.transcriptDisplayUTF8Count =
            transcriptDisplayUTF8Count
            ?? resolvedFingerprint.utf8Count
        self.transcriptDisplayFingerprint = resolvedFingerprint
        self.displayAppendBaseRevision = displayAppendBaseRevision
        self.displayAppendSuffix = displayAppendSuffix
    }

    static func == (
        lhs: ChatMessageDerivedSnapshot,
        rhs: ChatMessageDerivedSnapshot
    ) -> Bool {
        lhs.transcriptDisplayText == rhs.transcriptDisplayText
            && lhs.inlineAttachments == rhs.inlineAttachments
            && lhs.isTranscriptNoise == rhs.isTranscriptNoise
            && lhs.isInertAssistantStreamingPlaceholder
                == rhs.isInertAssistantStreamingPlaceholder
            && lhs.isInertAssistantPlaceholder
                == rhs.isInertAssistantPlaceholder
    }

    var estimatedResidentBytes: Int {
        transcriptDisplayUTF8Count
            + inlineAttachments.reduce(into: 0) { total, attachment in
                total += attachment.path.utf8.count
                total += attachment.name?.utf8.count ?? 0
            }
            + 192
    }
}

struct ChatMessageDerivedCacheMetrics: Equatable {
    var hits = 0
    var misses = 0
    var computations = 0
    var fullComputations = 0
    var incrementalComputations = 0
    var incrementalFallbacks = 0
    /// UTF-8 bytes actually inspected by the incremental transcript projector.
    /// This excludes retained committed text that was not revisited.
    var incrementalProjectionBytesScanned = 0
    /// Bytes passed through a whole-display fingerprint rebuild after an
    /// incremental mutation. Healthy append-only streaming keeps this at zero.
    var incrementalWholeDisplayBytesRehashed = 0
    var incrementalWholeDisplayRehashes = 0
    var evictions = 0
    var oversizedBypasses = 0
    var entryCount = 0
    var residentBytes = 0
}

struct ChatMessageDerivedAppendDelta {
    let baseRevision: UUID
    let suffix: String
}

struct ChatMessageDerivedAppendState {
    var committedDisplay: String
    var committedDisplayLineCount: Int
    var committedDisplayUTF8Count: Int
    var pendingSource: String
    var pendingSourceUTF8Count: Int
    var lastConsumedNewlineWasCarriageReturn: Bool
    var memoryCitationPrefixDisplay: String?
    var memoryCitationPrefixDisplayUTF8Count: Int
    var memoryCitationPrefixDisplayLineCount: Int
    var memoryCitationSawClosingLine: Bool
    var committedAttachments: [ChatInlineAttachment]
    var committedAttachmentsResidentBytes: Int
    var committedAttachmentPaths: Set<String>
    var committedAttachmentPathsResidentBytes: Int

    var estimatedResidentBytes: Int {
        committedDisplayUTF8Count
            + pendingSourceUTF8Count
            + (memoryCitationPrefixDisplay?.utf8.count ?? 0)
            + committedAttachmentsResidentBytes
            + committedAttachmentPathsResidentBytes
            + 256
    }
}

struct ChatMessageDerivedIncrementalWork {
    var projectionBytesScanned = 0
    var wholeDisplayBytesRehashed = 0
    var wholeDisplayRehashes = 0
}

struct ChatMessageDerivedResolution {
    let snapshot: ChatMessageDerivedSnapshot
    let appendState: ChatMessageDerivedAppendState?
    let incrementalWork: ChatMessageDerivedIncrementalWork?

    init(
        snapshot: ChatMessageDerivedSnapshot,
        appendState: ChatMessageDerivedAppendState?,
        incrementalWork: ChatMessageDerivedIncrementalWork? = nil
    ) {
        self.snapshot = snapshot
        self.appendState = appendState
        self.incrementalWork = incrementalWork
    }

    var estimatedResidentBytes: Int {
        snapshot.estimatedResidentBytes
            + (appendState?.estimatedResidentBytes ?? 0)
    }
}

/// Small O(1) LRU used by the transcript caches. The previous implementation
/// found the oldest dictionary entry with `min`, turning every eviction into an
/// O(n) scan on the main-thread layout path.
final class ChatTranscriptLRUStorage<Key: Hashable, Value> {
    private final class Node {
        let key: Key
        var value: Value
        weak var previous: Node?
        var next: Node?

        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }

    private var nodes: [Key: Node] = [:]
    private var mostRecent: Node?
    private var leastRecent: Node?

    var count: Int { nodes.count }

    func value(forKey key: Key) -> Value? {
        guard let node = nodes[key] else { return nil }
        moveToMostRecent(node)
        return node.value
    }

    @discardableResult
    func updateValue(_ value: Value, forKey key: Key) -> Value? {
        if let node = nodes[key] {
            let previousValue = node.value
            node.value = value
            moveToMostRecent(node)
            return previousValue
        }
        let node = Node(key: key, value: value)
        nodes[key] = node
        node.next = mostRecent
        mostRecent?.previous = node
        mostRecent = node
        if leastRecent == nil {
            leastRecent = node
        }
        return nil
    }

    func removeLeastRecentlyUsed() -> (key: Key, value: Value)? {
        guard let node = leastRecent else { return nil }
        unlink(node)
        nodes.removeValue(forKey: node.key)
        return (node.key, node.value)
    }

    func removeValue(forKey key: Key) -> Value? {
        guard let node = nodes.removeValue(forKey: key) else { return nil }
        unlink(node)
        return node.value
    }

    func removeAll(keepingCapacity: Bool = true) {
        nodes.removeAll(keepingCapacity: keepingCapacity)
        mostRecent = nil
        leastRecent = nil
    }

    private func moveToMostRecent(_ node: Node) {
        guard mostRecent !== node else { return }
        unlink(node)
        node.previous = nil
        node.next = mostRecent
        mostRecent?.previous = node
        mostRecent = node
        if leastRecent == nil {
            leastRecent = node
        }
    }

    private func unlink(_ node: Node) {
        let previous = node.previous
        let next = node.next
        previous?.next = next
        next?.previous = previous
        if mostRecent === node {
            mostRecent = next
        }
        if leastRecent === node {
            leastRecent = previous
        }
        node.previous = nil
        node.next = nil
    }
}

/// Process-local, bounded LRU for expensive transcript-derived values.
///
/// Recreated `ChatMessage` values with the same stable ID and content reuse the
/// exact cached `String`/attachment storage. Streaming changes update the
/// message fingerprints once and therefore cannot return a stale snapshot.
final class ChatMessageDerivedValueCache: @unchecked Sendable {
    static let shared = ChatMessageDerivedValueCache()

    private final class Entry {
        var key: ChatMessageDerivedCacheKey
        let resolution: ChatMessageDerivedResolution
        let residentBytes: Int

        init(
            key: ChatMessageDerivedCacheKey,
            resolution: ChatMessageDerivedResolution,
            residentBytes: Int
        ) {
            self.key = key
            self.resolution = resolution
            self.residentBytes = residentBytes
        }
    }

    let maximumEntryCount: Int
    let maximumResidentBytes: Int

    private let lock = NSLock()
    private let entries =
        ChatTranscriptLRUStorage<String, Entry>()
    private var residentByteCount = 0
    private var counters = ChatMessageDerivedCacheMetrics()

    init(
        maximumEntryCount: Int = 384,
        maximumResidentBytes: Int = 12 * 1_024 * 1_024
    ) {
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.maximumResidentBytes = max(1, maximumResidentBytes)
    }

    func resolve(
        key: ChatMessageDerivedCacheKey,
        build: () -> ChatMessageDerivedSnapshot
    ) -> ChatMessageDerivedSnapshot {
        resolve(
            key: key,
            appendDelta: nil,
            buildFull: {
                ChatMessageDerivedResolution(
                    snapshot: build(),
                    appendState: nil)
            },
            buildIncremental: { _, _ in nil })
    }

    func resolve(
        key: ChatMessageDerivedCacheKey,
        appendDelta: ChatMessageDerivedAppendDelta?,
        buildFull: () -> ChatMessageDerivedResolution,
        buildIncremental: (
            ChatMessageDerivedResolution,
            ChatMessageDerivedAppendDelta
        ) -> ChatMessageDerivedResolution?
    ) -> ChatMessageDerivedSnapshot {
        var incrementalCandidate:
            (ChatMessageDerivedResolution, ChatMessageDerivedAppendDelta)?
        lock.lock()
        if let entry = entries.value(forKey: key.messageID),
           entry.key == key
        {
            // Reconstructed values may carry a fresh mutation token despite
            // exact source equality. Adopt it so the next provenance-backed
            // append can still use the incremental path.
            entry.key = key
            counters.hits += 1
            updateFootprintMetrics()
            lock.unlock()
            return entry.resolution.snapshot
        }
        if let entry = entries.value(forKey: key.messageID),
           let appendDelta,
           entry.key.textRevision == appendDelta.baseRevision,
           entry.key.matchesNonTextFields(of: key),
           entry.key.textFingerprint.appending(appendDelta.suffix)
                == key.textFingerprint
        {
            incrementalCandidate = (entry.resolution, appendDelta)
        }
        counters.misses += 1
        lock.unlock()

        let resolution: ChatMessageDerivedResolution
        let usedIncrementalPath: Bool
        if let incrementalCandidate,
           let incremental = buildIncremental(
                incrementalCandidate.0,
                incrementalCandidate.1)
        {
            resolution = incremental
            usedIncrementalPath = true
        } else {
            if incrementalCandidate != nil {
                lock.lock()
                counters.incrementalFallbacks += 1
                lock.unlock()
            }
            resolution = buildFull()
            usedIncrementalPath = false
        }
        let bytes =
            key.estimatedResidentBytes
            + resolution.estimatedResidentBytes

        lock.lock()
        defer { lock.unlock() }
        counters.computations += 1
        if usedIncrementalPath {
            counters.incrementalComputations += 1
            if let work = resolution.incrementalWork {
                counters.incrementalProjectionBytesScanned +=
                    work.projectionBytesScanned
                counters.incrementalWholeDisplayBytesRehashed +=
                    work.wholeDisplayBytesRehashed
                counters.incrementalWholeDisplayRehashes +=
                    work.wholeDisplayRehashes
            }
        } else {
            counters.fullComputations += 1
        }
        if let racedEntry = entries.value(forKey: key.messageID),
           racedEntry.key == key
        {
            racedEntry.key = key
            // This lookup already counted as a miss before doing the build.
            // A concurrent insertion must not turn one lookup into both a miss
            // and a hit in the accounting.
            updateFootprintMetrics()
            return racedEntry.resolution.snapshot
        }
        if let replaced = entries.removeValue(forKey: key.messageID) {
            residentByteCount -= replaced.residentBytes
        }
        guard bytes <= maximumResidentBytes else {
            counters.oversizedBypasses += 1
            updateFootprintMetrics()
            return resolution.snapshot
        }
        let inserted = Entry(
            key: key,
            resolution: resolution,
            residentBytes: bytes)
        entries.updateValue(inserted, forKey: key.messageID)
        residentByteCount += inserted.residentBytes
        evictIfNeeded()
        updateFootprintMetrics()
        return resolution.snapshot
    }

    func metricsSnapshot() -> ChatMessageDerivedCacheMetrics {
        lock.lock()
        defer { lock.unlock() }
        updateFootprintMetrics()
        return counters
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        residentByteCount = 0
        counters = ChatMessageDerivedCacheMetrics()
    }

    private func evictIfNeeded() {
        while entries.count > maximumEntryCount
            || residentByteCount > maximumResidentBytes
        {
            guard let removed = entries.removeLeastRecentlyUsed()
            else { break }
            residentByteCount -= removed.value.residentBytes
            counters.evictions += 1
        }
    }

    private func updateFootprintMetrics() {
        counters.entryCount = entries.count
        counters.residentBytes = residentByteCount
    }
}

extension ChatMessage {
    var transcriptDisplayText: String {
        derivedSnapshot.transcriptDisplayText
    }

    var transcriptTextView: Text {
        derivedSnapshot.transcriptTextView
    }

    var inlineAttachments: [ChatInlineAttachment] {
        derivedSnapshot.inlineAttachments
    }

    var isTranscriptNoise: Bool {
        derivedSnapshot.isTranscriptNoise
    }

    var isInertAssistantStreamingPlaceholder: Bool {
        derivedSnapshot.isInertAssistantStreamingPlaceholder
    }

    var isInertAssistantPlaceholder: Bool {
        derivedSnapshot.isInertAssistantPlaceholder
    }

    func derivedSnapshot(
        using cache: ChatMessageDerivedValueCache
    ) -> ChatMessageDerivedSnapshot {
        cache.resolve(
            key: ChatMessageDerivedCacheKey(
                messageID: id,
                role: role.storageValue,
                text: text,
                status: status,
                textFingerprint: derivedTextFingerprint,
                statusFingerprint: derivedStatusFingerprint,
                statusWasNil: derivedStatusWasNil,
                eventKind: eventKind.rawValue,
                hasPlanQuestions: !planQuestions.isEmpty,
                textRevision: derivedTextRevision),
            appendDelta: {
                guard let baseRevision = derivedTextAppendBaseRevision,
                      let suffix = derivedTextAppendSuffix
                else { return nil }
                return ChatMessageDerivedAppendDelta(
                    baseRevision: baseRevision,
                    suffix: suffix)
            }(),
            buildFull: {
                Self.computeDerivedResolution(
                    text: text,
                    role: role,
                    status: status,
                    eventKind: eventKind,
                    hasPlanQuestions: !planQuestions.isEmpty)
            },
            buildIncremental: { previous, delta in
                Self.incrementallyComputeDerivedResolution(
                    previous: previous,
                    appendDelta: delta,
                    text: text,
                    role: role,
                    status: status,
                    eventKind: eventKind,
                    hasPlanQuestions: !planQuestions.isEmpty)
            })
    }

    private var derivedSnapshot: ChatMessageDerivedSnapshot {
        derivedSnapshot(using: .shared)
    }

    private static func computeDerivedResolution(
        text: String,
        role: ChatMessageRole,
        status: String?,
        eventKind: TatwoNativeChatEventKind,
        hasPlanQuestions: Bool
    ) -> ChatMessageDerivedResolution {
        let displayText = cleanedTranscriptDisplayText(text, role: role)
        let attachments = attachments(in: text)
        // Remote work is intentionally encoded as a tool-use event so the row
        // can render its structured inline lifecycle. It is user-facing Chat
        // state, not historical tool noise, and must survive filtering.
        let transcriptNoise =
            ChatRemoteJobInlinePresentation.payload(from: status) == nil
            && TatwoChatTranscriptPresentation.isTranscriptNoise(
                text,
                role: role.transcriptPresentationRole,
                status: status,
                eventKind: eventKind)
        let snapshot = makeDerivedSnapshot(
            displayText: displayText,
            attachments: attachments,
            text: text,
            role: role,
            status: status,
            eventKind: eventKind,
            hasPlanQuestions: hasPlanQuestions,
            transcriptNoise: transcriptNoise)
        return ChatMessageDerivedResolution(
            snapshot: snapshot,
            appendState: makeAppendState(
                text: text,
                role: role,
                expectedDisplayText: displayText,
                expectedAttachments: attachments))
    }

    private static func incrementallyComputeDerivedResolution(
        previous: ChatMessageDerivedResolution,
        appendDelta: ChatMessageDerivedAppendDelta,
        text: String,
        role: ChatMessageRole,
        status: String?,
        eventKind: TatwoNativeChatEventKind,
        hasPlanQuestions: Bool
    ) -> ChatMessageDerivedResolution? {
        guard var state = previous.appendState,
              role == .assistant,
              eventKind == .message
        else { return nil }
        let previousCommittedLineCount = state.committedDisplayLineCount
        let previousCommittedUTF8Count = state.committedDisplayUTF8Count
        let previousCitationWasHidden =
            hasCompleteTrailingMemoryCitation(state)
        let previousPendingDisplay = pendingDisplayText(
            state.pendingSource,
            citationIsHidden: previousCitationWasHidden)
        var work = ChatMessageDerivedIncrementalWork()
        work.projectionBytesScanned +=
            appendSource(appendDelta.suffix, to: &state)
        work.projectionBytesScanned +=
            state.pendingSourceUTF8Count
        let displayAppendSuffix = incrementalDisplaySuffix(
            previousCommittedLineCount: previousCommittedLineCount,
            previousCommittedUTF8Count: previousCommittedUTF8Count,
            previousPendingDisplay: previousPendingDisplay,
            previousDisplayText:
                previous.snapshot.transcriptDisplayText,
            previousCitationWasHidden: previousCitationWasHidden,
            updatedState: state)
        let derived: (
            displayText: String,
            attachments: [ChatInlineAttachment]
        )
        if let displayAppendSuffix {
            var display = previous.snapshot.transcriptDisplayText
            display.append(contentsOf: displayAppendSuffix)
            derived = (
                displayText: display,
                attachments: currentAttachments(from: state))
        } else {
            derived = currentDerivedValues(from: state)
        }
        let displayFingerprint = displayAppendSuffix.map {
            previous.snapshot.transcriptDisplayFingerprint.appending($0)
        } ?? {
            work.wholeDisplayRehashes += 1
            work.wholeDisplayBytesRehashed += derived.displayText.utf8.count
            return ChatStableContentFingerprint(derived.displayText)
        }()
        let snapshot = makeDerivedSnapshot(
            displayText: derived.displayText,
            attachments: derived.attachments,
            text: text,
            role: role,
            status: status,
            eventKind: eventKind,
            hasPlanQuestions: hasPlanQuestions,
            // A stable ordinary assistant prefix cannot become an anchored
            // internal artifact through suffix-only mutation.
            transcriptNoise: previous.snapshot.isTranscriptNoise,
            displayFingerprint: displayFingerprint,
            displayAppendBaseRevision:
                displayAppendSuffix == nil ? nil : appendDelta.baseRevision,
            displayAppendSuffix: displayAppendSuffix)
        return ChatMessageDerivedResolution(
            snapshot: snapshot,
            appendState: state,
            incrementalWork: work)
    }

    private static func makeDerivedSnapshot(
        displayText: String,
        attachments: [ChatInlineAttachment],
        text: String,
        role: ChatMessageRole,
        status: String?,
        eventKind: TatwoNativeChatEventKind,
        hasPlanQuestions: Bool,
        transcriptNoise: Bool,
        displayFingerprint: ChatStableContentFingerprint? = nil,
        displayAppendBaseRevision: UUID? = nil,
        displayAppendSuffix: String? = nil
    ) -> ChatMessageDerivedSnapshot {
        let normalizedStatus = status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let streamingPlaceholder =
            role == .assistant
            && eventKind == .message
            && attachments.isEmpty
            && displayText.isEmpty
            && !hasPlanQuestions
            && (normalizedStatus == "streaming"
                || normalizedStatus == "stream")

        let inertPlaceholder: Bool
        if hasPlanQuestions {
            // A `/plan` row can consist entirely of an interactive question.
            inertPlaceholder = false
        } else if streamingPlaceholder {
            inertPlaceholder = true
        } else if role != .assistant
            || eventKind != .message
            || !attachments.isEmpty
            || !displayText.isEmpty
        {
            inertPlaceholder = false
        } else if TatwoChatTranscriptPresentation.usesCompactActivity(
            role: role.transcriptPresentationRole,
            eventKind: eventKind,
            text: text,
            status: status)
        {
            inertPlaceholder = false
        } else {
            let actionableMarkers = [
                "fail",
                "error",
                "approval",
                "permission",
                "blocked",
                "conflict",
            ]
            inertPlaceholder = !actionableMarkers.contains {
                normalizedStatus?.contains($0) == true
            }
        }

        return ChatMessageDerivedSnapshot(
            transcriptDisplayText: displayText,
            transcriptTextView: Text(displayText),
            inlineAttachments: attachments,
            isTranscriptNoise: transcriptNoise,
            isInertAssistantStreamingPlaceholder: streamingPlaceholder,
            isInertAssistantPlaceholder: inertPlaceholder,
            transcriptDisplayFingerprint: displayFingerprint,
            displayAppendBaseRevision: displayAppendBaseRevision,
            displayAppendSuffix: displayAppendSuffix)
    }

    private static func cleanedTranscriptDisplayText(
        _ raw: String,
        role: ChatMessageRole
    ) -> String {
        let cleanedSource =
            TatwoChatTranscriptPresentation.cleanedTranscriptSource(
                raw,
                role: role.transcriptPresentationRole)
        let source = removingTrailingMemoryCitationLines(
            from: cleanedSource)

        var output: [String] = []
        for line in normalizedTranscriptLines(in: source) {
            if shouldHideTranscriptLine(line) { continue }
            output.append(line)
        }
        return output
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingTrailingMemoryCitationLines(
        from source: String
    ) -> String {
        let lines = normalizedTranscriptLines(in: source)
        guard let closingIndex = lines.lastIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }),
        lines[closingIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            == "</oai-mem-citation>",
        let openingIndex = lines[..<closingIndex].lastIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                == "<oai-mem-citation>"
        })
        else { return source }
        return lines[..<openingIndex].joined(separator: "\n")
    }

    private static func isStandaloneMarkdownAttachmentLine(_ line: String) -> Bool {
        guard line.hasPrefix("![") else { return false }
        return line.contains("](/") && line.hasSuffix(")")
    }

    private static func makeAppendState(
        text: String,
        role: ChatMessageRole,
        expectedDisplayText: String,
        expectedAttachments: [ChatInlineAttachment]
    ) -> ChatMessageDerivedAppendState? {
        guard role == .assistant,
              hasStableAssistantLeadingContent(text),
              TatwoChatTranscriptPresentation.cleanedTranscriptSource(
                text,
                role: role.transcriptPresentationRole) == text
        else { return nil }

        var state = ChatMessageDerivedAppendState(
            committedDisplay: "",
            committedDisplayLineCount: 0,
            committedDisplayUTF8Count: 0,
            pendingSource: "",
            pendingSourceUTF8Count: 0,
            lastConsumedNewlineWasCarriageReturn: false,
            memoryCitationPrefixDisplay: nil,
            memoryCitationPrefixDisplayUTF8Count: 0,
            memoryCitationPrefixDisplayLineCount: 0,
            memoryCitationSawClosingLine: false,
            committedAttachments: [],
            committedAttachmentsResidentBytes: 0,
            committedAttachmentPaths: [],
            committedAttachmentPathsResidentBytes: 0)
        _ = appendSource(text, to: &state)
        let derived = currentDerivedValues(from: state)
        guard derived.displayText == expectedDisplayText,
              derived.attachments == expectedAttachments
        else { return nil }
        return state
    }

    private static func hasStableAssistantLeadingContent(
        _ text: String
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let unstablePrefixes = [
            "<codex_internal_context",
            "<subagent_notification>",
            "# Files mentioned by the user:",
            "## My request for Codex:",
        ]
        return !unstablePrefixes.contains {
            $0.hasPrefix(trimmed) || trimmed.hasPrefix($0)
        }
    }

    @discardableResult
    private static func appendSource(
        _ suffix: String,
        to state: inout ChatMessageDerivedAppendState
    ) -> Int {
        guard !suffix.isEmpty else { return 0 }
        let scannedBytes = suffix.utf8.count
        for scalar in suffix.unicodeScalars {
            switch scalar.value {
            case 0x0D:
                commitPendingLine(to: &state)
                state.lastConsumedNewlineWasCarriageReturn = true
            case 0x0A:
                if state.lastConsumedNewlineWasCarriageReturn {
                    state.lastConsumedNewlineWasCarriageReturn = false
                } else {
                    commitPendingLine(to: &state)
                }
            default:
                if state.memoryCitationSawClosingLine,
                   !CharacterSet.whitespacesAndNewlines.contains(scalar)
                {
                    clearMemoryCitationCandidate(in: &state)
                }
                state.lastConsumedNewlineWasCarriageReturn = false
                let fragment = String(scalar)
                state.pendingSource.append(contentsOf: fragment)
                state.pendingSourceUTF8Count += fragment.utf8.count
            }
        }
        return scannedBytes
    }

    private static func commitPendingLine(
        to state: inout ChatMessageDerivedAppendState
    ) {
        commitStableLine(state.pendingSource, to: &state)
        state.pendingSource = ""
        state.pendingSourceUTF8Count = 0
    }

    private static func commitStableLine(
        _ line: String,
        to state: inout ChatMessageDerivedAppendState
    ) {
        let trimmed =
            line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "<oai-mem-citation>" {
            state.memoryCitationPrefixDisplay = state.committedDisplay
            state.memoryCitationPrefixDisplayUTF8Count =
                state.committedDisplayUTF8Count
            state.memoryCitationPrefixDisplayLineCount =
                state.committedDisplayLineCount
            state.memoryCitationSawClosingLine = false
        }
        if !shouldHideTranscriptLine(line) {
            if state.committedDisplayLineCount > 0 {
                state.committedDisplay.append("\n")
                state.committedDisplayUTF8Count += 1
            }
            state.committedDisplay.append(contentsOf: line)
            state.committedDisplayUTF8Count += line.utf8.count
            state.committedDisplayLineCount += 1
        }
        if trimmed == "</oai-mem-citation>",
           state.memoryCitationPrefixDisplay != nil
        {
            state.memoryCitationSawClosingLine = true
        }
        for attachment in attachments(in: line) {
            guard state.committedAttachmentPaths.insert(
                attachment.path).inserted
            else { continue }
            state.committedAttachments.append(attachment)
            state.committedAttachmentsResidentBytes +=
                attachment.path.utf8.count
                + (attachment.name?.utf8.count ?? 0)
            state.committedAttachmentPathsResidentBytes +=
                attachment.path.utf8.count
        }
    }

    private static func currentDerivedValues(
        from state: ChatMessageDerivedAppendState
    ) -> (displayText: String, attachments: [ChatInlineAttachment]) {
        let citationIsHidden = hasCompleteTrailingMemoryCitation(state)
        let pendingDisplay = pendingDisplayText(
            state.pendingSource,
            citationIsHidden: citationIsHidden)
        var display =
            citationIsHidden
            ? (state.memoryCitationPrefixDisplay ?? "")
            : state.committedDisplay
        if !pendingDisplay.isEmpty {
            let visibleLineCount =
                citationIsHidden
                ? state.memoryCitationPrefixDisplayLineCount
                : state.committedDisplayLineCount
            if visibleLineCount > 0 {
                display.append("\n")
            }
            display.append(contentsOf: pendingDisplay)
        }
        display = display.trimmingCharacters(in: .whitespacesAndNewlines)

        return (
            display,
            currentAttachments(from: state)
        )
    }

    private static func currentAttachments(
        from state: ChatMessageDerivedAppendState
    ) -> [ChatInlineAttachment] {
        var resultAttachments = state.committedAttachments
        var seen = state.committedAttachmentPaths
        for attachment in attachments(in: state.pendingSource) {
            guard seen.insert(attachment.path).inserted else { continue }
            resultAttachments.append(attachment)
        }
        return resultAttachments
    }

    private static func incrementalDisplaySuffix(
        previousCommittedLineCount: Int,
        previousCommittedUTF8Count: Int,
        previousPendingDisplay: String,
        previousDisplayText: String,
        previousCitationWasHidden: Bool,
        updatedState: ChatMessageDerivedAppendState
    ) -> String? {
        let updatedCitationIsHidden =
            hasCompleteTrailingMemoryCitation(updatedState)
        guard previousCitationWasHidden == updatedCitationIsHidden else {
            return nil
        }
        if updatedCitationIsHidden {
            return ""
        }
        guard updatedState.committedDisplayLineCount
                == previousCommittedLineCount
              && updatedState.committedDisplayUTF8Count
                == previousCommittedUTF8Count
        else { return nil }
        let updatedPendingDisplay =
            pendingDisplayText(
                updatedState.pendingSource,
                citationIsHidden: false)
        let previousVisibleTail = visiblePendingTail(
            previousPendingDisplay,
            priorDisplayIsEmpty: previousDisplayText.isEmpty)
        let updatedVisibleTail = visiblePendingTail(
            updatedPendingDisplay,
            priorDisplayIsEmpty: previousDisplayText.isEmpty)
        guard updatedVisibleTail.hasPrefix(previousVisibleTail) else {
            return nil
        }
        return String(
            updatedVisibleTail.dropFirst(previousVisibleTail.count))
    }

    private static func visiblePendingTail(
        _ source: String,
        priorDisplayIsEmpty: Bool
    ) -> String {
        let visible = trimmingTrailingWhitespaceAndNewlines(source)
        guard !visible.isEmpty else { return "" }
        if priorDisplayIsEmpty {
            return visible.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "\n" + visible
    }

    private static func trimmingTrailingWhitespaceAndNewlines(
        _ source: String
    ) -> String {
        var end = source.endIndex
        while end > source.startIndex {
            let candidate = source.index(before: end)
            guard source[candidate].isWhitespace else { break }
            end = candidate
        }
        return String(source[..<end])
    }

    private static func pendingDisplayText(
        _ source: String,
        citationIsHidden: Bool
    ) -> String {
        guard !citationIsHidden, !shouldHideTranscriptLine(source) else {
            return ""
        }
        return source
    }

    private static func hasCompleteTrailingMemoryCitation(
        _ state: ChatMessageDerivedAppendState
    ) -> Bool {
        guard state.memoryCitationPrefixDisplay != nil else { return false }
        if state.memoryCitationSawClosingLine {
            return state.pendingSource
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
        return state.pendingSource
            .trimmingCharacters(in: .whitespacesAndNewlines)
            == "</oai-mem-citation>"
    }

    private static func clearMemoryCitationCandidate(
        in state: inout ChatMessageDerivedAppendState
    ) {
        state.memoryCitationPrefixDisplay = nil
        state.memoryCitationPrefixDisplayUTF8Count = 0
        state.memoryCitationPrefixDisplayLineCount = 0
        state.memoryCitationSawClosingLine = false
    }

    private static func normalizedTranscriptLines(
        in source: String
    ) -> [String] {
        var lines: [String] = []
        var line = ""
        var previousWasCarriageReturn = false
        for scalar in source.unicodeScalars {
            switch scalar.value {
            case 0x0D:
                lines.append(line)
                line = ""
                previousWasCarriageReturn = true
            case 0x0A:
                if previousWasCarriageReturn {
                    previousWasCarriageReturn = false
                } else {
                    lines.append(line)
                    line = ""
                }
            default:
                previousWasCarriageReturn = false
                line.append(contentsOf: String(scalar))
            }
        }
        lines.append(line)
        return lines
    }

    private static func shouldHideTranscriptLine(_ line: String) -> Bool {
        let leadingTrimmed = line.drop {
            $0 == " " || $0 == "\t"
        }
        if leadingTrimmed.hasPrefix("<image ")
            || leadingTrimmed.hasPrefix("<video ")
            || leadingTrimmed.hasPrefix("<file ")
        {
            return true
        }
        let trimmed =
            line.trimmingCharacters(in: .whitespacesAndNewlines)
        if isStandaloneMarkdownAttachmentLine(trimmed) {
            return true
        }
        return trimmed.hasPrefix("## ") && trimmed.contains(": /")
    }

    private static func attachments(in raw: String) -> [ChatInlineAttachment] {
        var result: [ChatInlineAttachment] = []
        var seen = Set<String>()

        func append(path rawPath: String, name rawName: String?) {
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"), !seen.contains(path) else { return }
            seen.insert(path)
            result.append(ChatInlineAttachment(
                path: path,
                name: rawName?.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        for line in normalizedTranscriptLines(in: raw) {
            if line.contains("<image")
                || line.contains("<video")
                || line.contains("<file")
            {
                for attachment in
                    ChatAttachmentTranscript.attachments(in: line)
                {
                    append(path: attachment.path, name: attachment.name)
                }
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("## "), let separator = trimmed.range(of: ": /") {
                let name = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<separator.lowerBound])
                let path = "/" + String(trimmed[separator.upperBound...])
                append(path: path, name: name)
            }
            if line.contains("![") {
                for match in regexCapturePairs(
                    regex: markdownAttachmentRegex,
                    in: line)
                {
                    append(path: match.1, name: match.0)
                }
            }
        }

        return result
    }

    private static let markdownAttachmentRegex =
        try! NSRegularExpression(
            pattern: #"!\[([^\]]*)\]\((/[^)]+)\)"#,
            options: [])

    private static func regexCapturePairs(
        regex: NSRegularExpression,
        in text: String
    ) -> [(String, String)] {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: nsRange).compactMap { match in
            guard match.numberOfRanges >= 3,
                  let first = Range(match.range(at: 1), in: text),
                  let second = Range(match.range(at: 2), in: text)
            else { return nil }
            return (String(text[first]), String(text[second]))
        }
    }

    var isCoworkCard: Bool {
        guard let status else { return false }
        return ["監工卡", "收據卡", "紅卡", "範圍警報", "停止卡"].contains(status)
    }

    fileprivate var coworkCardTint: Color {
        guard let status else { return .orange }
        if status == "紅卡" { return .red }
        if status == "範圍警報" { return .orange }
        if status == "收據卡" { return .green }
        if status == "停止卡" { return .gray }
        return .cyan
    }
}

struct CoworkCardBody: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let lines = message.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            Text(lines.first ?? "Ultrawork card")
                .font(.caption.weight(.black))
                .foregroundStyle(message.coworkCardTint)
            Text(lines.dropFirst().joined(separator: "\n"))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(message.coworkCardTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(message.coworkCardTint.opacity(0.30), lineWidth: 1))
    }
}

struct ChatInlineAttachment: Identifiable, Equatable {
    let path: String
    let name: String?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var displayName: String {
        let fallback = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return named.isEmpty ? (fallback.isEmpty ? "附件" : fallback) : named
    }
    var fileExtension: String {
        url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    var isImage: Bool {
        TatwoImageAssetStore.isImageCandidatePath(path)
    }
    var isVideo: Bool {
        ["mov", "mp4", "m4v", "webm"].contains(fileExtension)
    }
    var isMissing: Bool {
        !FileManager.default.fileExists(atPath: path)
    }
}

struct ChatModelAvatar: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let route: ChatRouteChoice
    var size: CGFloat = 24

    var body: some View {
        let cornerRadius = min(size / 2, LiquidGlassTokens.radiusChip)
        let softenedBrandColors = quotaBrandColors(route.providerIconID).map {
            $0.opacity(LiquidGlassTokens.tintOpacity)
        }

        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle)
                .fill(
                    LinearGradient(
                        colors: softenedBrandColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
            if let image = ProviderSVGIconLoader.image(for: route.providerIconID) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(size * LiquidGlassTokens.tintOpacity)
                    .opacity(1 - LiquidGlassTokens.tintOpacity)
            } else {
                Text(ProviderSVGIconLoader.fallbackInitials(for: route.providerIconID))
                    .font(.system(size: max(8, size * 0.36), weight: .black, design: .rounded))
                    .foregroundStyle(.primary.opacity(1 - LiquidGlassTokens.tintOpacity))
            }
        }
        .frame(width: size, height: size)
        .liquidGlassSurface(cornerRadius: cornerRadius)
        .accessibilityLabel("\(route.title) logo")
    }
}
