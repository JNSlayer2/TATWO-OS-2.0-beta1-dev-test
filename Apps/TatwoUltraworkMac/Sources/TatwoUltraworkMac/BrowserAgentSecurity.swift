import Combine
import CryptoKit
import Foundation

enum TatwoBrowserPerceptionMode: String, Codable, Sendable {
    case textSafe
    case visualReadOnly
}

enum TatwoBrowserAgentCapability: String, Codable, CaseIterable, Sendable {
    case readSanitized
    case planActions
    case executeApprovedPlan
    case securityAnalysis
    case visualReadOnly
}

struct TatwoBrowserAgentGrant: Codable, Equatable, Sendable {
    let schema: String
    let contractID: String
    let runID: String
    let leaseID: String
    let sessionID: String
    let origin: String
    let navigationGeneration: UInt64
    let capabilities: Set<TatwoBrowserAgentCapability>
    let perceptionMode: TatwoBrowserPerceptionMode
    let expiresAt: Date
    let nonce: String

    init(
        schema: String = "TatwoBrowserAgentGrantV1",
        contractID: String,
        runID: String,
        leaseID: String,
        sessionID: String,
        origin: String,
        navigationGeneration: UInt64,
        capabilities: Set<TatwoBrowserAgentCapability>,
        perceptionMode: TatwoBrowserPerceptionMode = .textSafe,
        expiresAt: Date,
        nonce: String
    ) {
        self.schema = schema
        self.contractID = contractID
        self.runID = runID
        self.leaseID = leaseID
        self.sessionID = sessionID
        self.origin = origin
        self.navigationGeneration = navigationGeneration
        self.capabilities = capabilities
        self.perceptionMode = perceptionMode
        self.expiresAt = expiresAt
        self.nonce = nonce
    }

    func validate(
        capability: TatwoBrowserAgentCapability,
        origin expectedOrigin: String,
        navigationGeneration expectedGeneration: UInt64,
        now: Date = Date()
    ) throws {
        guard schema == "TatwoBrowserAgentGrantV1",
              !contractID.isEmpty,
              !runID.isEmpty,
              !leaseID.isEmpty,
              !sessionID.isEmpty,
              !nonce.isEmpty
        else { throw TatwoBrowserSecurityError.invalidGrant }
        guard expiresAt > now else {
            throw TatwoBrowserSecurityError.grantExpired
        }
        guard capabilities.contains(capability) else {
            throw TatwoBrowserSecurityError.capabilityDenied
        }
        guard origin == expectedOrigin,
              navigationGeneration == expectedGeneration
        else { throw TatwoBrowserSecurityError.staleSnapshot }
        if capability == .readSanitized,
           perceptionMode != .textSafe
        {
            throw TatwoBrowserSecurityError.perceptionModeMismatch
        }
        if capability == .visualReadOnly,
           perceptionMode != .visualReadOnly
        {
            throw TatwoBrowserSecurityError.perceptionModeMismatch
        }
    }
}

struct TatwoBrowserCommittedPageBindingV1: Equatable, Sendable {
    let sessionID: String
    let origin: String
    let navigationGeneration: UInt64

    init(
        sessionID: String,
        origin: String,
        navigationGeneration: UInt64
    ) throws {
        let normalizedSessionID = sessionID.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let normalizedOrigin = origin.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty,
              !normalizedOrigin.isEmpty,
              navigationGeneration > 0
        else {
            throw TatwoBrowserSecurityError.navigationBindingUnavailable
        }
        self.sessionID = normalizedSessionID
        self.origin = normalizedOrigin
        self.navigationGeneration = navigationGeneration
    }

    init(
        sessionID: String,
        committedURLString: String,
        navigationGeneration: UInt64
    ) throws {
        guard let components = URLComponents(
            string: committedURLString),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else {
            throw TatwoBrowserSecurityError.navigationBindingUnavailable
        }
        var origin = "\(scheme)://\(host)"
        if let port = components.port,
           !((scheme == "http" && port == 80)
                || (scheme == "https" && port == 443))
        {
            origin += ":\(port)"
        }
        try self.init(
            sessionID: sessionID,
            origin: origin,
            navigationGeneration: navigationGeneration)
    }
}

enum TatwoBrowserSecurityError: String, Error, LocalizedError, Sendable {
    case invalidGrant = "invalid_browser_grant"
    case grantExpired = "browser_grant_expired"
    case capabilityDenied = "browser_capability_denied"
    case perceptionModeMismatch = "browser_perception_mode_mismatch"
    case committedPageUnavailable = "committed_page_unavailable"
    case snapshotUnavailable = "snapshot_unavailable"
    case snapshotParseFailed = "snapshot_parse_failed"
    case navigationBindingUnavailable = "navigation_binding_unavailable"
    case staleSnapshot = "stale_snapshot"
    case invalidPlan = "invalid_browser_plan"
    case humanApprovalRequired = "human_approval_required"
    case planExpired = "browser_plan_expired"
    case planAlreadyConsumed = "browser_plan_already_consumed"
    case typedExecutorUnavailable = "typed_browser_executor_unavailable"

    var errorDescription: String? { rawValue }
}

struct TatwoBrowserViewportV1: Codable, Equatable, Sendable {
    let width: Double
    let height: Double
    let scrollX: Double
    let scrollY: Double
}

struct TatwoBrowserRectV1: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var centerCSV: String {
        "\(Int((x + width / 2).rounded())),\(Int((y + height / 2).rounded()))"
    }
}

struct TatwoBrowserVisibleTextBlockV1: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let text: String
    let kind: String
    let sourceOrigin: String
    let rect: TatwoBrowserRectV1
    let lowContrast: Bool
    let unicodeRemovalCount: Int
}

struct TatwoBrowserLinkV1: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let sourceOrigin: String
    let destinationOrigin: String
    let destinationPath: String
    let rect: TatwoBrowserRectV1
}

struct TatwoBrowserFormFieldV1: Codable, Equatable, Sendable {
    let elementID: String
    let type: String
    let label: String
    let sensitive: Bool
}

struct TatwoBrowserFormV1: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let sourceOrigin: String
    let actionOrigin: String
    let method: String
    let fields: [TatwoBrowserFormFieldV1]
    let rect: TatwoBrowserRectV1?
}

struct TatwoBrowserExcludedCountsV1: Codable, Equatable, Sendable {
    var crossOriginFrames = 0
    var hidden = 0
    var ariaHidden = 0
    var opacity = 0
    var tinyText = 0
    var offscreen = 0
    var clipped = 0
    var occluded = 0
    var lowContrast = 0
    var sensitiveFields = 0
    var instructionLike = 0
    var unicodeScalars = 0
    var truncatedBlocks = 0
    var truncatedLinks = 0
    var truncatedForms = 0
}

enum TatwoBrowserRiskFlagV1: String, Codable, CaseIterable, Sendable {
    case instructionLikeContent
    case unicodeControlCharactersRemoved
    case lowContrastContentExcluded
    case crossOriginFrameExcluded
    case sensitiveFieldsRedacted
    case truncated
    case occlusionUnverified
    case sanitizerDegraded
}

struct TatwoUntrustedPageEnvelopeV1: Codable, Equatable, Sendable {
    let schema: String
    let trust: String
    let snapshotID: String
    let origin: String
    let navigationGeneration: UInt64
    let snapshotHash: String
    let viewport: TatwoBrowserViewportV1
    let visibleTextBlocks: [TatwoBrowserVisibleTextBlockV1]
    let links: [TatwoBrowserLinkV1]
    let forms: [TatwoBrowserFormV1]
    let excludedCounts: TatwoBrowserExcludedCountsV1
    let riskFlags: [TatwoBrowserRiskFlagV1]
    let truncated: Bool

    init(
        snapshotID: String,
        origin: String,
        navigationGeneration: UInt64,
        snapshotHash: String,
        viewport: TatwoBrowserViewportV1,
        visibleTextBlocks: [TatwoBrowserVisibleTextBlockV1],
        links: [TatwoBrowserLinkV1],
        forms: [TatwoBrowserFormV1],
        excludedCounts: TatwoBrowserExcludedCountsV1,
        riskFlags: Set<TatwoBrowserRiskFlagV1>,
        truncated: Bool
    ) {
        schema = "TatwoUntrustedPageEnvelopeV1"
        trust = "untrusted_web"
        self.snapshotID = snapshotID
        self.origin = origin
        self.navigationGeneration = navigationGeneration
        self.snapshotHash = snapshotHash
        self.viewport = viewport
        self.visibleTextBlocks = visibleTextBlocks
        self.links = links
        self.forms = forms
        self.excludedCounts = excludedCounts
        self.riskFlags = riskFlags.sorted { $0.rawValue < $1.rawValue }
        self.truncated = truncated
    }
}

struct TatwoCEFVisibleSnapshotV1: Codable, Equatable, Sendable {
    struct Block: Codable, Equatable, Sendable {
        let elementID: String
        let text: String
        let kind: String
        let sourceOrigin: String
        let rect: TatwoBrowserRectV1
        let lowContrast: Bool
        let quarantined: Bool
    }

    struct Link: Codable, Equatable, Sendable {
        let elementID: String
        let label: String
        let sourceOrigin: String
        let destinationOrigin: String
        let destinationPath: String
        let rect: TatwoBrowserRectV1
    }

    struct Field: Codable, Equatable, Sendable {
        let elementID: String
        let type: String
        let label: String
        let sensitive: Bool
    }

    struct Form: Codable, Equatable, Sendable {
        let elementID: String
        let sourceOrigin: String
        let actionOrigin: String
        let method: String
        let fields: [Field]
        let rect: TatwoBrowserRectV1?
    }

    let schema: String
    let origin: String
    let navigationGeneration: UInt64
    let viewport: TatwoBrowserViewportV1
    let blocks: [Block]
    let links: [Link]
    let forms: [Form]
    let excludedCounts: TatwoBrowserExcludedCountsV1
    let riskFlags: Set<TatwoBrowserRiskFlagV1>
}

struct TatwoUnicodeSanitizationResult: Equatable, Sendable {
    let text: String
    let removedScalarCount: Int
}

enum TatwoBrowserUnicodeSanitizer {
    static func sanitize(_ input: String) -> TatwoUnicodeSanitizationResult {
        let normalized = input.precomposedStringWithCanonicalMapping
        var scalars = String.UnicodeScalarView()
        var removed = 0
        for scalar in normalized.unicodeScalars {
            if shouldRemove(scalar.value) {
                removed += 1
                continue
            }
            if scalar.value < 0x20,
               scalar.value != 0x09,
               scalar.value != 0x0A,
               scalar.value != 0x0D
            {
                removed += 1
                continue
            }
            scalars.append(scalar)
        }
        let collapsed = String(scalars)
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(text: collapsed, removedScalarCount: removed)
    }

    private static func shouldRemove(_ value: UInt32) -> Bool {
        switch value {
        case 0x00AD,
             0x034F,
             0x061C,
             0x115F...0x1160,
             0x17B4...0x17B5,
             0x180B...0x180F,
             0x200B...0x200F,
             0x202A...0x202E,
             0x2060...0x206F,
             0x3164,
             0xFE00...0xFE0F,
             0xFEFF,
             0xFFA0,
             0xFFF0...0xFFF8,
             0x1BCA0...0x1BCAF,
             0xE0000...0xE007F,
             0xE0100...0xE01EF:
            true
        default:
            false
        }
    }
}

enum TatwoBrowserInstructionDetector {
    private static let phrases = [
        "ignore previous", "ignore all previous", "ignore above",
        "system message", "developer message", "reveal secret",
        "show your prompt", "api key", "access token", "session cookie",
        "disable safety", "bypass safety", "execute command", "run command",
        "download this", "upload this", "make payment", "send payment",
        "log in", "sign in", "send data", "exfiltrate",
        "忽略之前", "忽略以上", "忽略所有", "系統訊息", "系统消息",
        "開發者訊息", "开发者消息", "洩露", "泄露", "提示詞", "提示词",
        "停用安全", "绕过安全", "繞過安全", "執行命令", "执行命令",
        "下載", "下载", "上傳", "上传", "付款", "支付", "登入", "登录",
        "傳送資料", "发送数据", "密碼", "密码", "驗證碼", "验证码",
    ]

    static func isInstructionLike(_ input: String) -> Bool {
        let normalized = TatwoBrowserUnicodeSanitizer.sanitize(input)
            .text.lowercased()
        return phrases.contains { normalized.contains($0) }
    }
}

enum TatwoBrowserEnvelopeBuilder {
    static let maximumBlocks = 2_000
    static let maximumTextBytes = 256 * 1_024
    static let maximumForms = 32
    static let maximumLinks = 512

    static func build(
        raw: TatwoCEFVisibleSnapshotV1,
        grant: TatwoBrowserAgentGrant,
        now: Date = Date()
    ) throws -> TatwoUntrustedPageEnvelopeV1 {
        guard raw.schema == "TatwoCEFVisibleSnapshotV1",
              !raw.origin.isEmpty
        else { throw TatwoBrowserSecurityError.snapshotParseFailed }
        try grant.validate(
            capability: .readSanitized,
            origin: raw.origin,
            navigationGeneration: raw.navigationGeneration,
            now: now)

        var counts = raw.excludedCounts
        var flags = raw.riskFlags
        var blocks: [TatwoBrowserVisibleTextBlockV1] = []
        var textBytes = 0
        for candidate in raw.blocks {
            guard blocks.count < maximumBlocks else {
                counts.truncatedBlocks += 1
                flags.insert(.truncated)
                continue
            }
            let sanitized = TatwoBrowserUnicodeSanitizer.sanitize(candidate.text)
            counts.unicodeScalars += sanitized.removedScalarCount
            if sanitized.removedScalarCount > 0 {
                flags.insert(.unicodeControlCharactersRemoved)
            }
            guard !candidate.quarantined,
                  !sanitized.text.isEmpty
            else { continue }
            if TatwoBrowserInstructionDetector.isInstructionLike(sanitized.text) {
                counts.instructionLike += 1
                flags.insert(.instructionLikeContent)
                continue
            }
            if candidate.lowContrast {
                counts.lowContrast += 1
                flags.insert(.lowContrastContentExcluded)
                continue
            }
            let byteCount = sanitized.text.lengthOfBytes(using: .utf8)
            guard textBytes + byteCount <= maximumTextBytes else {
                counts.truncatedBlocks += 1
                flags.insert(.truncated)
                continue
            }
            textBytes += byteCount
            blocks.append(.init(
                id: candidate.elementID,
                text: sanitized.text,
                kind: candidate.kind,
                sourceOrigin: candidate.sourceOrigin,
                rect: candidate.rect,
                lowContrast: candidate.lowContrast,
                unicodeRemovalCount: sanitized.removedScalarCount))
        }

        let safeLinks = raw.links.prefix(maximumLinks).map {
            let label = TatwoBrowserUnicodeSanitizer.sanitize($0.label).text
            return TatwoBrowserLinkV1(
                id: $0.elementID,
                label: TatwoBrowserInstructionDetector.isInstructionLike(label)
                    ? "" : label,
                sourceOrigin: $0.sourceOrigin,
                destinationOrigin: $0.destinationOrigin,
                destinationPath: $0.destinationPath,
                rect: $0.rect)
        }
        if raw.links.count > safeLinks.count {
            counts.truncatedLinks += raw.links.count - safeLinks.count
            flags.insert(.truncated)
        }

        let safeForms = raw.forms.prefix(maximumForms).map { form in
            TatwoBrowserFormV1(
                id: form.elementID,
                sourceOrigin: form.sourceOrigin,
                actionOrigin: form.actionOrigin,
                method: form.method,
                fields: form.fields.map {
                    if $0.sensitive { counts.sensitiveFields += 1 }
                    return TatwoBrowserFormFieldV1(
                        elementID: $0.elementID,
                        type: $0.type,
                        label: TatwoBrowserInstructionDetector.isInstructionLike(
                            $0.label) ? "" : TatwoBrowserUnicodeSanitizer
                            .sanitize($0.label).text,
                        sensitive: $0.sensitive)
                },
                rect: form.rect)
        }
        if counts.sensitiveFields > 0 {
            flags.insert(.sensitiveFieldsRedacted)
        }
        if raw.forms.count > safeForms.count {
            counts.truncatedForms += raw.forms.count - safeForms.count
            flags.insert(.truncated)
        }

        let snapshotID = UUID().uuidString.lowercased()
        let hashPayload = TatwoEnvelopeHashPayload(
            origin: raw.origin,
            navigationGeneration: raw.navigationGeneration,
            viewport: raw.viewport,
            visibleTextBlocks: blocks,
            links: Array(safeLinks),
            forms: Array(safeForms),
            excludedCounts: counts,
            riskFlags: flags.sorted { $0.rawValue < $1.rawValue })
        let hash = try TatwoBrowserCanonicalJSON.sha256(hashPayload)
        return .init(
            snapshotID: snapshotID,
            origin: raw.origin,
            navigationGeneration: raw.navigationGeneration,
            snapshotHash: hash,
            viewport: raw.viewport,
            visibleTextBlocks: blocks,
            links: Array(safeLinks),
            forms: Array(safeForms),
            excludedCounts: counts,
            riskFlags: flags,
            truncated: flags.contains(.truncated))
    }
}

private struct TatwoEnvelopeHashPayload: Codable {
    let origin: String
    let navigationGeneration: UInt64
    let viewport: TatwoBrowserViewportV1
    let visibleTextBlocks: [TatwoBrowserVisibleTextBlockV1]
    let links: [TatwoBrowserLinkV1]
    let forms: [TatwoBrowserFormV1]
    let excludedCounts: TatwoBrowserExcludedCountsV1
    let riskFlags: [TatwoBrowserRiskFlagV1]
}

enum TatwoBrowserCanonicalJSON {
    static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }

    static func sha256<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try data(value))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private extension Collection {
    func tatwoUniqueDictionary<Key: Hashable>(
        keyedBy key: (Element) -> Key
    ) throws -> [Key: Element] {
        var result: [Key: Element] = [:]
        for element in self {
            let identifier = key(element)
            guard result[identifier] == nil else {
                throw TatwoBrowserSecurityError.invalidPlan
            }
            result[identifier] = element
        }
        return result
    }
}

enum TatwoBrowserTypedActionKind: String, Codable, Sendable {
    case click
    case doubleClick
    case typeText
    case pressKey
    case scroll
    case webMCP
}

enum TatwoBrowserSensitiveActionKind: String, Codable, Sendable {
    case formSubmit
    case login
    case oauth
    case passwordOrOTP
    case upload
    case download
    case payment
    case subscription
    case accountSettings
    case delete
    case externalOpen
    case crossOriginTransfer
}

struct TatwoBrowserRequestedActionV1: Codable, Equatable, Sendable {
    let elementID: String
    let action: TatwoBrowserTypedActionKind
    let value: String?
}

struct TatwoBrowserTypedActionV1: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let elementID: String
    let action: TatwoBrowserTypedActionKind
    let parameterDigest: String
    let executionValue: String
    let destinationOrigin: String?
    let sensitiveKinds: Set<TatwoBrowserSensitiveActionKind>
}

enum TatwoBrowserPlanState: String, Codable, Sendable {
    case read = "READ"
    case planFrozen = "PLAN_FROZEN"
    case humanApproved = "HUMAN_APPROVED"
    case executeTyped = "EXECUTE_TYPED"
    case verify = "VERIFY"
    case staleSnapshot = "STALE_SNAPSHOT"
    case stopped = "STOPPED"
}

struct TatwoBrowserTypedPlanTokenV1: Codable, Equatable, Sendable {
    let schema: String
    let tokenID: String
    let contractID: String
    let runID: String
    let leaseID: String
    let sessionID: String
    let snapshotID: String
    let snapshotHash: String
    let origin: String
    let navigationGeneration: UInt64
    let actions: [TatwoBrowserTypedActionV1]
    let expiresAt: Date
    let nonce: String
    let planHash: String
}

struct TatwoBrowserPlanThenExecuteStateMachine: Equatable, Sendable {
    private(set) var state: TatwoBrowserPlanState = .read
    private(set) var token: TatwoBrowserTypedPlanTokenV1?
    private(set) var humanApprovalReceiptID: String?

    mutating func freeze(_ token: TatwoBrowserTypedPlanTokenV1) throws {
        guard state == .read else {
            throw TatwoBrowserSecurityError.invalidPlan
        }
        self.token = token
        state = .planFrozen
    }

    mutating func observe(
        snapshotHash: String,
        origin: String,
        navigationGeneration: UInt64
    ) {
        guard let token, state != .read else { return }
        if token.snapshotHash != snapshotHash
            || token.origin != origin
            || token.navigationGeneration != navigationGeneration
        {
            state = .staleSnapshot
        }
    }

    mutating func approve(receiptID: String) throws {
        guard state == .planFrozen, !receiptID.isEmpty else {
            throw TatwoBrowserSecurityError.invalidPlan
        }
        humanApprovalReceiptID = receiptID
        state = .humanApproved
    }

    mutating func beginExecution(now: Date = Date()) throws {
        guard state == .humanApproved,
              let token
        else { throw TatwoBrowserSecurityError.humanApprovalRequired }
        guard token.expiresAt > now else {
            state = .stopped
            throw TatwoBrowserSecurityError.planExpired
        }
        state = .executeTyped
    }

    mutating func requireVerification() throws {
        guard state == .executeTyped else {
            throw TatwoBrowserSecurityError.invalidPlan
        }
        state = .verify
    }

    mutating func verified(hasRemainingActions: Bool) throws {
        guard state == .verify else {
            throw TatwoBrowserSecurityError.invalidPlan
        }
        humanApprovalReceiptID = nil
        state = hasRemainingActions ? .planFrozen : .stopped
    }
}

private struct TatwoBrowserPlanHashAction: Codable {
    let id: String
    let elementID: String
    let action: TatwoBrowserTypedActionKind
    let parameterDigest: String
    let executionValue: String
    let destinationOrigin: String?
    let sensitiveKinds: [TatwoBrowserSensitiveActionKind]
}

private struct TatwoBrowserPlanHashPayload: Codable {
    let tokenID: String
    let contractID: String
    let runID: String
    let leaseID: String
    let sessionID: String
    let snapshotID: String
    let snapshotHash: String
    let origin: String
    let navigationGeneration: UInt64
    let actions: [TatwoBrowserPlanHashAction]
    let expiresAt: Date
    let nonce: String
}

enum TatwoBrowserTypedPlanFactory {
    static func freeze(
        envelope: TatwoUntrustedPageEnvelopeV1,
        grant: TatwoBrowserAgentGrant,
        requestedActions: [TatwoBrowserRequestedActionV1],
        ttl: TimeInterval = 120,
        now: Date = Date()
    ) throws -> TatwoBrowserTypedPlanTokenV1 {
        try grant.validate(
            capability: .planActions,
            origin: envelope.origin,
            navigationGeneration: envelope.navigationGeneration,
            now: now)
        guard !requestedActions.isEmpty,
              requestedActions.count <= 32,
              ttl > 0,
              ttl <= 300
        else { throw TatwoBrowserSecurityError.invalidPlan }

        let links = try envelope.links.tatwoUniqueDictionary(keyedBy: \.id)
        let fields = try envelope.forms.flatMap(\.fields)
            .tatwoUniqueDictionary(keyedBy: \.elementID)
        let forms = try envelope.forms.tatwoUniqueDictionary(keyedBy: \.id)
        let blocks = try envelope.visibleTextBlocks
            .tatwoUniqueDictionary(keyedBy: \.id)

        var actions: [TatwoBrowserTypedActionV1] = []
        for request in requestedActions {
            let link = links[request.elementID]
            let field = fields[request.elementID]
            let form = forms[request.elementID]
            let block = blocks[request.elementID]
            guard link != nil || field != nil || form != nil || block != nil
            else { throw TatwoBrowserSecurityError.invalidPlan }
            if field?.sensitive == true, request.action == .typeText {
                throw TatwoBrowserSecurityError.capabilityDenied
            }

            let rawValue = request.value ?? ""
            let executionValue: String
            let destinationOrigin: String?
            var sensitive: Set<TatwoBrowserSensitiveActionKind> = []
            switch request.action {
            case .webMCP:
                // WebMCP actions may only be constructed by freezeWebMCP,
                // which binds the tool to origin, navigation generation,
                // registry binding hash, expiry, and argument digest.
                throw TatwoBrowserSecurityError.invalidPlan
            case .click, .doubleClick:
                guard rawValue.isEmpty else {
                    throw TatwoBrowserSecurityError.invalidPlan
                }
                if let link {
                    executionValue = link.rect.centerCSV
                    destinationOrigin = link.destinationOrigin
                    sensitive.insert(.externalOpen)
                    if link.destinationOrigin != envelope.origin {
                        sensitive.insert(.crossOriginTransfer)
                    }
                    sensitive.formUnion(inferredSensitiveKinds(
                        "\(link.label) \(link.destinationPath)"))
                } else if let form {
                    guard let rect = form.rect else {
                        throw TatwoBrowserSecurityError.invalidPlan
                    }
                    executionValue = rect.centerCSV
                    destinationOrigin = form.actionOrigin
                    sensitive.insert(.formSubmit)
                    if form.actionOrigin != envelope.origin {
                        sensitive.insert(.crossOriginTransfer)
                    }
                    let formProbe = form.fields.map {
                        "\($0.type) \($0.label)"
                    }.joined(separator: " ")
                    sensitive.formUnion(inferredSensitiveKinds(formProbe))
                    if form.fields.contains(where: {
                        $0.type.lowercased() == "file"
                    }) {
                        sensitive.insert(.upload)
                    }
                    if form.fields.contains(where: \.sensitive) {
                        sensitive.insert(.passwordOrOTP)
                    }
                } else if let block {
                    executionValue = block.rect.centerCSV
                    destinationOrigin = nil
                    sensitive.insert(.externalOpen)
                } else {
                    throw TatwoBrowserSecurityError.invalidPlan
                }
            case .typeText:
                guard field != nil,
                      !rawValue.isEmpty,
                      rawValue.lengthOfBytes(using: .utf8) <= 4_096
                else { throw TatwoBrowserSecurityError.invalidPlan }
                executionValue = rawValue
                destinationOrigin = nil
            case .pressKey:
                guard !rawValue.isEmpty,
                      rawValue.count <= 64
                else { throw TatwoBrowserSecurityError.invalidPlan }
                executionValue = rawValue
                destinationOrigin = nil
                if ["enter", "return"].contains(rawValue.lowercased()) {
                    sensitive.insert(.formSubmit)
                }
            case .scroll:
                guard rawValue.split(separator: ",").count == 4 else {
                    throw TatwoBrowserSecurityError.invalidPlan
                }
                executionValue = rawValue
                destinationOrigin = nil
            }

            actions.append(.init(
                id: UUID().uuidString.lowercased(),
                elementID: request.elementID,
                action: request.action,
                parameterDigest: SHA256.hash(data: Data(rawValue.utf8))
                    .map { String(format: "%02x", $0) }.joined(),
                executionValue: executionValue,
                destinationOrigin: destinationOrigin,
                sensitiveKinds: sensitive))
        }

        let tokenID = UUID().uuidString.lowercased()
        let nonce = UUID().uuidString.lowercased()
        // MCP JSONValue transport uses ISO-8601 seconds. Freeze the wire value
        // at the same precision so the returned token remains byte-for-byte
        // equal to the in-process human-gate record.
        let expiresAt = Date(
            timeIntervalSince1970:
                floor(now.addingTimeInterval(ttl).timeIntervalSince1970))
        let payload = TatwoBrowserPlanHashPayload(
            tokenID: tokenID,
            contractID: grant.contractID,
            runID: grant.runID,
            leaseID: grant.leaseID,
            sessionID: grant.sessionID,
            snapshotID: envelope.snapshotID,
            snapshotHash: envelope.snapshotHash,
            origin: envelope.origin,
            navigationGeneration: envelope.navigationGeneration,
            actions: actions.map {
                TatwoBrowserPlanHashAction(
                    id: $0.id,
                    elementID: $0.elementID,
                    action: $0.action,
                    parameterDigest: $0.parameterDigest,
                    executionValue: $0.executionValue,
                    destinationOrigin: $0.destinationOrigin,
                    sensitiveKinds: $0.sensitiveKinds.sorted {
                        $0.rawValue < $1.rawValue
                    })
            },
            expiresAt: expiresAt,
            nonce: nonce)
        return .init(
            schema: "TatwoBrowserTypedPlanTokenV1",
            tokenID: tokenID,
            contractID: grant.contractID,
            runID: grant.runID,
            leaseID: grant.leaseID,
            sessionID: grant.sessionID,
            snapshotID: envelope.snapshotID,
            snapshotHash: envelope.snapshotHash,
            origin: envelope.origin,
            navigationGeneration: envelope.navigationGeneration,
            actions: actions,
            expiresAt: expiresAt,
            nonce: nonce,
            planHash: try TatwoBrowserCanonicalJSON.sha256(payload))
    }

    static func freezeWebMCP(
        grant: TatwoBrowserAgentGrant,
        toolName: String,
        origin: String,
        navigationGeneration: UInt64,
        bindingHash: String,
        argumentsJSON: String,
        ttl: TimeInterval = 120,
        now: Date = Date()
    ) throws -> TatwoBrowserTypedPlanTokenV1 {
        try grant.validate(
            capability: .planActions,
            origin: origin,
            navigationGeneration: navigationGeneration,
            now: now)
        guard toolName.hasPrefix("tatwo.webmcp."),
              !origin.isEmpty,
              navigationGeneration > 0,
              bindingHash.count == 64,
              ttl > 0,
              ttl <= 300,
              let argumentsData = argumentsJSON.data(using: .utf8),
              argumentsData.count <= 1_048_576,
              (try? JSONSerialization.jsonObject(
                  with: argumentsData,
                  options: [.fragmentsAllowed])) != nil
        else {
            throw TatwoBrowserSecurityError.invalidPlan
        }

        let action = TatwoBrowserTypedActionV1(
            id: UUID().uuidString.lowercased(),
            elementID: toolName,
            action: .webMCP,
            parameterDigest: SHA256.hash(data: argumentsData)
                .map { String(format: "%02x", $0) }
                .joined(),
            executionValue: argumentsJSON,
            destinationOrigin: origin,
            sensitiveKinds: [.externalOpen])
        let tokenID = UUID().uuidString.lowercased()
        let nonce = UUID().uuidString.lowercased()
        let expiresAt = Date(
            timeIntervalSince1970:
                floor(now.addingTimeInterval(ttl).timeIntervalSince1970))
        let payload = TatwoBrowserPlanHashPayload(
            tokenID: tokenID,
            contractID: grant.contractID,
            runID: grant.runID,
            leaseID: grant.leaseID,
            sessionID: grant.sessionID,
            snapshotID: "webmcp:\(toolName)",
            snapshotHash: bindingHash,
            origin: origin,
            navigationGeneration: navigationGeneration,
            actions: [
                TatwoBrowserPlanHashAction(
                    id: action.id,
                    elementID: action.elementID,
                    action: action.action,
                    parameterDigest: action.parameterDigest,
                    executionValue: action.executionValue,
                    destinationOrigin: action.destinationOrigin,
                    sensitiveKinds: action.sensitiveKinds.sorted {
                        $0.rawValue < $1.rawValue
                    }),
            ],
            expiresAt: expiresAt,
            nonce: nonce)
        return TatwoBrowserTypedPlanTokenV1(
            schema: "TatwoBrowserTypedPlanTokenV1",
            tokenID: tokenID,
            contractID: grant.contractID,
            runID: grant.runID,
            leaseID: grant.leaseID,
            sessionID: grant.sessionID,
            snapshotID: "webmcp:\(toolName)",
            snapshotHash: bindingHash,
            origin: origin,
            navigationGeneration: navigationGeneration,
            actions: [action],
            expiresAt: expiresAt,
            nonce: nonce,
            planHash: try TatwoBrowserCanonicalJSON.sha256(payload))
    }

    private static func inferredSensitiveKinds(
        _ rawProbe: String
    ) -> Set<TatwoBrowserSensitiveActionKind> {
        let probe = TatwoBrowserUnicodeSanitizer.sanitize(rawProbe)
            .text.lowercased()
        var result: Set<TatwoBrowserSensitiveActionKind> = []
        if ["login", "log in", "sign in", "signin", "登入", "登录"]
            .contains(where: probe.contains)
        {
            result.insert(.login)
        }
        if ["oauth", "authorize", "authorization", "授權", "授权"]
            .contains(where: probe.contains)
        {
            result.insert(.oauth)
        }
        if ["password", "one-time", "otp", "密碼", "密码", "驗證碼", "验证码"]
            .contains(where: probe.contains)
        {
            result.insert(.passwordOrOTP)
        }
        if ["upload", "上傳", "上传"].contains(where: probe.contains) {
            result.insert(.upload)
        }
        if ["download", "下載", "下载"].contains(where: probe.contains) {
            result.insert(.download)
        }
        if [
            "payment", "pay", "checkout", "billing", "credit card",
            "付款", "支付", "結帳", "结账",
        ].contains(where: probe.contains) {
            result.insert(.payment)
        }
        if ["subscribe", "subscription", "訂閱", "订阅"]
            .contains(where: probe.contains)
        {
            result.insert(.subscription)
        }
        if ["account", "settings", "帳號", "账号", "設定", "设置"]
            .contains(where: probe.contains)
        {
            result.insert(.accountSettings)
        }
        if ["delete", "remove", "刪除", "删除"]
            .contains(where: probe.contains)
        {
            result.insert(.delete)
        }
        return result
    }
}

final class TatwoBrowserAgentSecurityRuntime: @unchecked Sendable {
    static let shared = TatwoBrowserAgentSecurityRuntime()

    private struct StoredSnapshot {
        let envelope: TatwoUntrustedPageEnvelopeV1
        let contractID: String
        let runID: String
        let leaseID: String
        let sessionID: String
    }

    private struct StoredPlan {
        var machine: TatwoBrowserPlanThenExecuteStateMachine
        var nextActionIndex: Int
    }

    private let lock = NSLock()
    private var grantsByNonce: [String: TatwoBrowserAgentGrant] = [:]
    private var snapshotsByHash: [String: StoredSnapshot] = [:]
    private var plansByID: [String: StoredPlan] = [:]

    private init() {}

    func issueGrant(
        contractID: String,
        runID: String,
        leaseID: String,
        sessionID: String,
        origin: String,
        navigationGeneration: UInt64,
        capabilities: Set<TatwoBrowserAgentCapability>,
        perceptionMode: TatwoBrowserPerceptionMode = .textSafe,
        ttl: TimeInterval = 180,
        now: Date = Date()
    ) throws -> TatwoBrowserAgentGrant {
        guard ttl > 0, ttl <= 300 else {
            throw TatwoBrowserSecurityError.invalidGrant
        }
        let grant = TatwoBrowserAgentGrant(
            contractID: contractID,
            runID: runID,
            leaseID: leaseID,
            sessionID: sessionID,
            origin: origin,
            navigationGeneration: navigationGeneration,
            capabilities: capabilities,
            perceptionMode: perceptionMode,
            expiresAt: Date(
                timeIntervalSince1970:
                    floor(now.addingTimeInterval(ttl).timeIntervalSince1970)),
            nonce: UUID().uuidString.lowercased())
        guard !capabilities.isEmpty,
              !contractID.isEmpty,
              !runID.isEmpty,
              !leaseID.isEmpty,
              !sessionID.isEmpty,
              !origin.isEmpty
        else { throw TatwoBrowserSecurityError.invalidGrant }
        if perceptionMode == .textSafe {
            guard !capabilities.contains(.visualReadOnly) else {
                throw TatwoBrowserSecurityError.perceptionModeMismatch
            }
        } else {
            guard capabilities == [.visualReadOnly] else {
                throw TatwoBrowserSecurityError.perceptionModeMismatch
            }
        }
        lock.lock()
        purgeExpiredLocked(now: now)
        grantsByNonce[grant.nonce] = grant
        lock.unlock()
        return grant
    }

    func validateRegistered(
        _ grant: TatwoBrowserAgentGrant,
        capability: TatwoBrowserAgentCapability,
        origin: String,
        navigationGeneration: UInt64,
        now: Date = Date()
    ) throws {
        try grant.validate(
            capability: capability,
            origin: origin,
            navigationGeneration: navigationGeneration,
            now: now)
        lock.lock()
        defer { lock.unlock() }
        purgeExpiredLocked(now: now)
        guard grantsByNonce[grant.nonce] == grant else {
            throw TatwoBrowserSecurityError.invalidGrant
        }
    }

    func record(
        envelope: TatwoUntrustedPageEnvelopeV1,
        grant: TatwoBrowserAgentGrant,
        now: Date = Date()
    ) throws {
        try validateRegistered(
            grant,
            capability: .readSanitized,
            origin: envelope.origin,
            navigationGeneration: envelope.navigationGeneration,
            now: now)
        lock.lock()
        snapshotsByHash[envelope.snapshotHash] = StoredSnapshot(
            envelope: envelope,
            contractID: grant.contractID,
            runID: grant.runID,
            leaseID: grant.leaseID,
            sessionID: grant.sessionID)
        lock.unlock()
        Task { @MainActor in
            TatwoBrowserSecurityProjection.shared.show(
                envelope: envelope,
                mode: grant.perceptionMode)
        }
    }

    func freezePlan(
        grant: TatwoBrowserAgentGrant,
        snapshotHash: String,
        requestedActions: [TatwoBrowserRequestedActionV1],
        now: Date = Date()
    ) throws -> TatwoBrowserTypedPlanTokenV1 {
        lock.lock()
        let storedSnapshot = snapshotsByHash[snapshotHash]
        lock.unlock()
        guard let storedSnapshot,
              storedSnapshot.contractID == grant.contractID,
              storedSnapshot.runID == grant.runID,
              storedSnapshot.leaseID == grant.leaseID,
              storedSnapshot.sessionID == grant.sessionID
        else {
            throw TatwoBrowserSecurityError.staleSnapshot
        }
        let envelope = storedSnapshot.envelope
        try validateRegistered(
            grant,
            capability: .planActions,
            origin: envelope.origin,
            navigationGeneration: envelope.navigationGeneration,
            now: now)
        let token = try TatwoBrowserTypedPlanFactory.freeze(
            envelope: envelope,
            grant: grant,
            requestedActions: requestedActions,
            now: now)
        var machine = TatwoBrowserPlanThenExecuteStateMachine()
        try machine.freeze(token)
        lock.lock()
        plansByID[token.tokenID] = .init(
            machine: machine,
            nextActionIndex: 0)
        lock.unlock()
        Task { @MainActor in
            TatwoBrowserSecurityProjection.shared.show(token: token)
        }
        return token
    }

    func freezeWebMCPPlan(
        grant: TatwoBrowserAgentGrant,
        toolName: String,
        origin: String,
        navigationGeneration: UInt64,
        bindingHash: String,
        argumentsJSON: String,
        now: Date = Date()
    ) throws -> TatwoBrowserTypedPlanTokenV1 {
        try validateRegistered(
            grant,
            capability: .planActions,
            origin: origin,
            navigationGeneration: navigationGeneration,
            now: now)
        let token = try TatwoBrowserTypedPlanFactory.freezeWebMCP(
            grant: grant,
            toolName: toolName,
            origin: origin,
            navigationGeneration: navigationGeneration,
            bindingHash: bindingHash,
            argumentsJSON: argumentsJSON,
            now: now)
        var machine = TatwoBrowserPlanThenExecuteStateMachine()
        try machine.freeze(token)
        lock.lock()
        plansByID[token.tokenID] = .init(
            machine: machine,
            nextActionIndex: 0)
        lock.unlock()
        Task { @MainActor in
            TatwoBrowserSecurityProjection.shared.show(token: token)
        }
        return token
    }

    func approveFromHumanUI(
        tokenID: String,
        now: Date = Date()
    ) throws -> String {
        let receiptID = "browser-human-\(UUID().uuidString.lowercased())"
        lock.lock()
        defer { lock.unlock() }
        purgeExpiredLocked(now: now)
        guard var stored = plansByID[tokenID] else {
            throw TatwoBrowserSecurityError.invalidPlan
        }
        try stored.machine.approve(receiptID: receiptID)
        plansByID[tokenID] = stored
        Task { @MainActor in
            TatwoBrowserSecurityProjection.shared.set(
                state: .humanApproved,
                approvalReceiptID: receiptID)
        }
        return receiptID
    }

    func prepareNextAction(
        approvedToken: TatwoBrowserTypedPlanTokenV1,
        grant: TatwoBrowserAgentGrant,
        currentSnapshotHash: String,
        currentOrigin: String,
        currentNavigationGeneration: UInt64,
        now: Date = Date()
    ) throws -> (TatwoBrowserTypedPlanTokenV1, TatwoBrowserTypedActionV1) {
        lock.lock()
        defer { lock.unlock() }
        purgeExpiredLocked(now: now)
        guard var stored = plansByID[approvedToken.tokenID],
              let token = stored.machine.token,
              token == approvedToken,
              token.contractID == grant.contractID,
              token.runID == grant.runID,
              token.leaseID == grant.leaseID,
              token.sessionID == grant.sessionID,
              stored.nextActionIndex < token.actions.count
        else { throw TatwoBrowserSecurityError.invalidPlan }
        try validateRegisteredLocked(
            grant,
            capability: .executeApprovedPlan,
            origin: token.origin,
            navigationGeneration: token.navigationGeneration,
            now: now)
        stored.machine.observe(
            snapshotHash: currentSnapshotHash,
            origin: currentOrigin,
            navigationGeneration: currentNavigationGeneration)
        guard stored.machine.state != .staleSnapshot else {
            plansByID[token.tokenID] = stored
            Task { @MainActor in
                TatwoBrowserSecurityProjection.shared.set(
                    state: .staleSnapshot)
            }
            throw TatwoBrowserSecurityError.staleSnapshot
        }
        try stored.machine.beginExecution(now: now)
        plansByID[token.tokenID] = stored
        let action = token.actions[stored.nextActionIndex]
        Task { @MainActor in
            TatwoBrowserSecurityProjection.shared.set(state: .executeTyped)
        }
        return (token, action)
    }

    func requireVerification(
        tokenID: String,
        actionSucceeded: Bool
    ) throws -> TatwoBrowserPlanState {
        lock.lock()
        defer { lock.unlock() }
        guard var stored = plansByID[tokenID] else {
            throw TatwoBrowserSecurityError.invalidPlan
        }
        guard actionSucceeded else {
            plansByID.removeValue(forKey: tokenID)
            Task { @MainActor in
                TatwoBrowserSecurityProjection.shared.set(state: .stopped)
            }
            return .stopped
        }
        try stored.machine.requireVerification()
        stored.nextActionIndex += 1
        let hasRemaining = stored.nextActionIndex
            < (stored.machine.token?.actions.count ?? 0)
        try stored.machine.verified(hasRemainingActions: hasRemaining)
        plansByID[tokenID] = stored
        let finalState = stored.machine.state
        let projectedPendingActions = hasRemaining
            ? Array((stored.machine.token?.actions ?? [])
                .dropFirst(stored.nextActionIndex))
            : []
        Task { @MainActor in
            TatwoBrowserSecurityProjection.shared.set(
                state: finalState,
                pendingActions: projectedPendingActions)
        }
        return finalState
    }

    private func purgeExpiredLocked(now: Date) {
        grantsByNonce = grantsByNonce.filter { $0.value.expiresAt > now }
        plansByID = plansByID.filter {
            ($0.value.machine.token?.expiresAt ?? .distantPast) > now
        }
    }

    private func validateRegisteredLocked(
        _ grant: TatwoBrowserAgentGrant,
        capability: TatwoBrowserAgentCapability,
        origin: String,
        navigationGeneration: UInt64,
        now: Date
    ) throws {
        try grant.validate(
            capability: capability,
            origin: origin,
            navigationGeneration: navigationGeneration,
            now: now)
        guard grantsByNonce[grant.nonce] == grant else {
            throw TatwoBrowserSecurityError.invalidGrant
        }
    }
}

@MainActor
final class TatwoBrowserSecurityProjection: ObservableObject {
    static let shared = TatwoBrowserSecurityProjection()

    @Published private(set) var perceptionMode: TatwoBrowserPerceptionMode =
        .textSafe
    @Published private(set) var origin = "尚未讀取"
    @Published private(set) var planState: TatwoBrowserPlanState = .read
    @Published private(set) var planHash = ""
    @Published private(set) var tokenID = ""
    @Published private(set) var pendingActions: [TatwoBrowserTypedActionV1] = []
    @Published private(set) var approvalReceiptID: String?
    @Published private(set) var protectionDegraded = false
    @Published private(set) var visibleError: String?

    private init() {}

    var awaitingHumanApproval: Bool {
        planState == .planFrozen && !tokenID.isEmpty
    }

    func show(
        envelope: TatwoUntrustedPageEnvelopeV1,
        mode: TatwoBrowserPerceptionMode
    ) {
        origin = envelope.origin
        perceptionMode = mode
        protectionDegraded = envelope.riskFlags.contains(.sanitizerDegraded)
        planState = .read
        visibleError = nil
    }

    func show(token: TatwoBrowserTypedPlanTokenV1) {
        tokenID = token.tokenID
        planHash = token.planHash
        origin = token.origin
        pendingActions = token.actions
        planState = .planFrozen
        approvalReceiptID = nil
        visibleError = nil
    }

    func approveCurrentPlan() {
        do {
            approvalReceiptID = try TatwoBrowserAgentSecurityRuntime.shared
                .approveFromHumanUI(tokenID: tokenID)
            planState = .humanApproved
            visibleError = nil
        } catch {
            visibleError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    func set(
        state: TatwoBrowserPlanState,
        approvalReceiptID: String? = nil,
        pendingActions: [TatwoBrowserTypedActionV1]? = nil
    ) {
        planState = state
        if let approvalReceiptID {
            self.approvalReceiptID = approvalReceiptID
        }
        if let pendingActions {
            self.pendingActions = pendingActions
        }
    }

    func showDegraded(_ error: String) {
        protectionDegraded = true
        visibleError = error
    }
}
