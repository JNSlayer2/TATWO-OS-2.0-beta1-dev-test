// 源自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/EmbeddedBrowserSecurity.swift；
// 薄殼移除 TatwoCEFBridge/TatwoUltraworkCore import，C2 加入僅 staging 的 loopback 例外。
import AppKit
import SwiftUI
import WebKit
import Darwin

enum EmbeddedBrowserNavigationBlockReason: Equatable, Sendable {
    case missingURL
    case unsupportedScheme
    case missingHost
    case localHostname
    case nonPublicIPAddress
}

enum EmbeddedBrowserNavigationDecision: Equatable, Sendable {
    case allow
    case askOncePerHost(String)
    case block(EmbeddedBrowserNavigationBlockReason)
}

/// C2: process-local staging exception, never a persisted browser preference.
enum StagingBrowserLoopbackPolicy {
    static let runtimeEnvironment = ProcessInfo.processInfo.environment
    static let runtimeBundleIdentifier = Bundle.main.bundleIdentifier

    static func enabledPort(environment: [String: String], bundleIdentifier: String?) -> Int? {
        guard environment["TATWO_STAGING_ALLOW_BROWSER_LOOPBACK"] == "1",
              NativeStagingIsolation.isEnabled(environment),
              let bundleIdentifier,
              bundleIdentifier != "ai.tatwo.tatwo2",
              bundleIdentifier.hasPrefix("ai.tatwo.tatwo2."),
              bundleIdentifier.count > "ai.tatwo.tatwo2.".count
        else { return nil }
        let text = environment["TATWO_STAGING_BROWSER_LOOPBACK_PORT"] ?? "8765"
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = Int(text), (1...65535).contains(port)
        else { return nil }
        return port
    }

    /// Check the untrimmed, percent-encoded host, not a canonicalized IP alias.
    static func allows(
        _ url: URL, environment: [String: String], bundleIdentifier: String?
    ) -> Bool {
        guard let port = enabledPort(environment: environment, bundleIdentifier: bundleIdentifier),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.percentEncodedHost == "127.0.0.1",
              components.port == port,
              components.user == nil, components.password == nil
        else { return false }
        return true
    }
}

enum EmbeddedBrowserNavigationPolicy {
    static func decision(
        for url: URL?,
        actor: BrowserActor = .strict,
        environment: [String: String] = StagingBrowserLoopbackPolicy.runtimeEnvironment,
        bundleIdentifier: String? = StagingBrowserLoopbackPolicy.runtimeBundleIdentifier
    ) -> EmbeddedBrowserNavigationDecision {
        guard let url else {
            BrowserPolicyLog.shared.record(decision: "navigation.block.missingURL", actor: actor == .human ? "human" : "agent")
            return .block(.missingURL)
        }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            BrowserPolicyLog.shared.record(host: url.host, decision: "navigation.block.unsupportedScheme", actor: actor == .human ? "human" : "agent")
            return .block(.unsupportedScheme)
        }
        guard var host = url.host?.lowercased(),
              !host.isEmpty
        else {
            BrowserPolicyLog.shared.record(decision: "navigation.block.missingHost", actor: actor == .human ? "human" : "agent")
            return .block(.missingHost)
        }

        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while host.hasSuffix(".") {
            host.removeLast()
        }

        if host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "local"
            || host.hasSuffix(".local")
            || host == "home.arpa"
            || host.hasSuffix(".home.arpa")
            || host == "internal"
            || host.hasSuffix(".internal")
            || host == "lan"
            || host.hasSuffix(".lan")
        {
            BrowserPolicyLog.shared.record(host: host, decision: actor == .human ? "navigation.askOncePerHost" : "navigation.block.localHostname", actor: actor == .human ? "human" : "agent")
            return actor == .human ? .askOncePerHost(host) : .block(.localHostname)
        }

        if StagingBrowserLoopbackPolicy.allows(
            url, environment: environment, bundleIdentifier: bundleIdentifier
        ) {
            BrowserPolicyLog.shared.record(host: host, decision: "navigation.allow.staging", actor: actor == .human ? "human" : "agent")
            return .allow
        }
        if let isPublic = publicIPv4Literal(host), !isPublic {
            BrowserPolicyLog.shared.record(host: host, decision: actor == .human ? "navigation.askOncePerHost" : "navigation.block.nonPublicIP", actor: actor == .human ? "human" : "agent")
            return actor == .human ? .askOncePerHost(host) : .block(.nonPublicIPAddress)
        }
        if let isPublic = publicIPv6Literal(host), !isPublic {
            BrowserPolicyLog.shared.record(host: host, decision: actor == .human ? "navigation.askOncePerHost" : "navigation.block.nonPublicIP", actor: actor == .human ? "human" : "agent")
            return actor == .human ? .askOncePerHost(host) : .block(.nonPublicIPAddress)
        }
        BrowserPolicyLog.shared.record(host: host, decision: "navigation.allow", actor: actor == .human ? "human" : "agent")
        return .allow
    }

    static func allows(_ url: URL?) -> Bool {
        decision(for: url) == .allow
    }

    private static func publicIPv4Literal(_ host: String) -> Bool? {
        var address = in_addr()
        guard inet_aton(host, &address) == 1 else {
            return nil
        }
        let value = UInt32(bigEndian: address.s_addr)
        let first = UInt8((value >> 24) & 0xff)
        let second = UInt8((value >> 16) & 0xff)
        let third = UInt8((value >> 8) & 0xff)

        switch (first, second, third) {
        case (0, _, _),
             (10, _, _),
             (100, 64 ... 127, _),
             (127, _, _),
             (169, 254, _),
             (172, 16 ... 31, _),
             (192, 0, _),
             (192, 168, _),
             (198, 18 ... 19, _):
            return false
        case (192, 0, 2),
             (198, 51, 100),
             (203, 0, 113):
            return false
        default:
            return first < 224
        }
    }

    private static func publicIPv6Literal(_ host: String) -> Bool? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else {
            return nil
        }
        let bytes = withUnsafeBytes(of: address) { Array($0) }

        if bytes.allSatisfy({ $0 == 0 }) {
            return false
        }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 {
            return false
        }
        if bytes[0] & 0xfe == 0xfc {
            return false
        }
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 {
            return false
        }
        if bytes[0] == 0xff {
            return false
        }
        if Array(bytes.prefix(4)) == [0x20, 0x01, 0x0d, 0xb8] {
            return false
        }
        if Array(bytes.prefix(12)) == Array(repeating: 0, count: 10) + [0xff, 0xff] {
            let embedded = bytes.suffix(4)
            let value = embedded.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let ipv4 = "\(value >> 24).\(value >> 16 & 0xff).\(value >> 8 & 0xff).\(value & 0xff)"
            return publicIPv4Literal(ipv4) ?? false
        }
        return true
    }
}

enum EmbeddedBrowserVisibleError: Equatable, Sendable {
    case blockedNavigation(EmbeddedBrowserNavigationBlockReason)
    case popupBlocked
    case downloadBlocked
    case unsupportedContent
    case sensitivePermissionBlocked(EmbeddedBrowserSensitivePermission)
    case loadFailed
    case runtimeMessage(String)

    var message: String {
        switch self {
        case .blockedNavigation(.missingURL):
            "安全限制：無法判定目標網址"
        case .blockedNavigation(.unsupportedScheme):
            "安全限制：僅允許公開 http 或 https 網址"
        case .blockedNavigation(.missingHost):
            "安全限制：網址缺少有效主機"
        case .blockedNavigation(.localHostname),
             .blockedNavigation(.nonPublicIPAddress):
            "安全限制：不允許連線到本機或私有網路"
        case .popupBlocked:
            "安全限制：已封鎖新視窗或外部開啟"
        case .downloadBlocked:
            "這個網站要求下載檔案，內建瀏覽器目前不允許下載"
        case .unsupportedContent:
            "安全限制：此內容無法安全顯示"
        case let .sensitivePermissionBlocked(permission):
            "已拒絕\(permission.visibleName)權限"
        case .loadFailed:
            "頁面載入失敗，請檢查網址或網路後重試"
        case let .runtimeMessage(message):
            message
        }
    }
}

enum EmbeddedBrowserSiteToolEffect: Equatable, Sendable {
    case readOnly
    case sideEffect
    case highRisk
}

struct EmbeddedBrowserSiteToolMetadata: Equatable, Sendable {
    let identifier: String
    let title: String
    let origin: URL
    let effect: EmbeddedBrowserSiteToolEffect
}

enum EmbeddedBrowserSiteToolDecision: Equatable, Sendable {
    case ask
    case requiresHumanApproval
    case reject
}

enum EmbeddedBrowserSiteToolPolicy {
    static func discoveryMetadata(
        from candidates: [EmbeddedBrowserSiteToolMetadata]
    ) -> [EmbeddedBrowserSiteToolMetadata] {
        candidates.filter {
            !$0.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && EmbeddedBrowserNavigationPolicy.allows($0.origin)
        }
    }

    static func decision(
        for metadata: EmbeddedBrowserSiteToolMetadata
    ) -> EmbeddedBrowserSiteToolDecision {
        guard EmbeddedBrowserNavigationPolicy.allows(metadata.origin),
              !metadata.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .reject
        }
        switch metadata.effect {
        case .readOnly:
            return .ask
        case .sideEffect, .highRisk:
            return .requiresHumanApproval
        }
    }
}

enum EmbeddedBrowserAutomationExposurePolicy {
    static let exposesCDPEndpoint = false
    static var supportsChromiumWebMCP: Bool {
        EmbeddedBrowserEnginePolicy.current == .chromiumCEF
            && TatwoCEFRuntime.supportsChromiumWebMCP
    }
}

enum EmbeddedBrowserSensitivePermission: Equatable, Sendable {
    case camera
    case microphone
    case cameraAndMicrophone
    case deviceOrientationAndMotion
    case geolocation

    var visibleName: String {
        switch self {
        case .camera: "相機"
        case .microphone: "麥克風"
        case .cameraAndMicrophone: "相機與麥克風"
        case .deviceOrientationAndMotion: "裝置方向與動作"
        case .geolocation: "位置"
        }
    }
}

enum EmbeddedBrowserSecurityStatusPresentation {
    static func title(for message: String) -> String {
        if message.contains("下載") {
            return "下載已阻擋"
        }
        if message.contains("權限") {
            return "網站權限已拒絕"
        }
        return "安全政策已阻擋導覽"
    }
}

enum EmbeddedBrowserSensitivePermissionDecision: Equatable, Sendable {
    case ask, deny
    var webKitDecision: WKPermissionDecision { self == .ask ? .prompt : .deny }
}

enum EmbeddedBrowserSensitivePermissionPolicy {
    static func decision(
        for permission: EmbeddedBrowserSensitivePermission,
        actor: BrowserActor = .strict
    ) -> EmbeddedBrowserSensitivePermissionDecision {
        BrowserPolicyLog.shared.record(decision: "permission.\(permission)." + (actor == .human ? "ask" : "deny"), actor: actor == .human ? "human" : "agent")
        return actor == .human ? .ask : .deny
    }
}

enum EmbeddedBrowserResponsePolicy {
    static func visibleError(
        url: URL?,
        canShowMIMEType: Bool,
        contentDisposition: String?
    ) -> EmbeddedBrowserVisibleError? {
        if case let .block(reason) = EmbeddedBrowserNavigationPolicy.decision(for: url) {
            return .blockedNavigation(reason)
        }
        if contentDisposition?
            .lowercased()
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "attachment"
        {
            return .downloadBlocked
        }
        return canShowMIMEType ? nil : .unsupportedContent
    }
}

extension WKWebViewConfiguration {
    static func tatwoBrowserConfiguration(
        profile: EmbeddedBrowserRuntimeProfile
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        if let identifier = profile.dataStoreIdentifier {
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: identifier)
        } else {
            configuration.websiteDataStore = .nonPersistent()
        }
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }
}

struct EmbeddedBrowserCommand: Equatable {
    enum Action: Equatable {
        case load(URL)
        case goBack
        case goForward
        case reload
        case stopLoading
        case printPage
        case printPDF
        case openPDF
        case find(String, forward: Bool, matchCase: Bool)
        case stopFinding
        case zoom(Double)
    }

    let id = UUID()
    let action: Action
    let agentNavigation: BrowserAgentNavigation?

    init(action: Action, agentNavigation: BrowserAgentNavigation? = nil) {
        self.action = action
        self.agentNavigation = agentNavigation
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.action == rhs.action
            && lhs.agentNavigation === rhs.agentNavigation
    }
}

enum EmbeddedBrowserLoadPhase: String, Equatable, Sendable {
    case blank
    case creating
    case loading
    case committed
    case finished
    case blockedBySecurity
    case navigationFailed
    case rendererFailed
    case startupFailed
    case closed
}

enum EmbeddedBrowserNavigationErrorKind: String, Equatable, Sendable {
    case security
    case navigation
    case renderer
    case startup
}

struct EmbeddedBrowserNavigationError: Equatable, Sendable {
    let kind: EmbeddedBrowserNavigationErrorKind
    let code: Int?
    let message: String
}

struct EmbeddedBrowserNavigationState: Equatable {
    static let blank = EmbeddedBrowserNavigationState(
        urlString: nil,
        canGoBack: false,
        canGoForward: false,
        visibleError: nil)

    let urlString: String?
    let canGoBack: Bool
    let canGoForward: Bool
    let visibleError: EmbeddedBrowserVisibleError?
    let isLoading: Bool
    let phase: EmbeddedBrowserLoadPhase
    let committedMainFrameURLString: String?
    /// Preserve whether the native producer actually supplied a commit URL;
    /// the legacy display fallback below is not evidence of a commit.
    let hasExplicitCommittedURL: Bool
    let navigationGeneration: UInt64
    let httpStatusCode: Int?
    let structuredError: EmbeddedBrowserNavigationError?

    init(
        urlString: String?,
        canGoBack: Bool,
        canGoForward: Bool,
        visibleError: EmbeddedBrowserVisibleError?,
        isLoading: Bool = false,
        phase: EmbeddedBrowserLoadPhase = .blank,
        committedMainFrameURLString: String? = nil,
        navigationGeneration: UInt64 = 0,
        httpStatusCode: Int? = nil,
        structuredError: EmbeddedBrowserNavigationError? = nil
    ) {
        self.urlString = urlString
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.visibleError = visibleError
        self.isLoading = isLoading
        self.phase = phase
        self.hasExplicitCommittedURL = committedMainFrameURLString?.isEmpty == false
        self.committedMainFrameURLString =
            committedMainFrameURLString ?? urlString
        self.navigationGeneration = navigationGeneration
        self.httpStatusCode = httpStatusCode
        self.structuredError = structuredError
    }
}

enum EmbeddedBrowserSurfaceCondition: Equatable {
    case none
    case pageCreating
    case loadedAwaitingPaint
    case blockedBySecurity(message: String)
    case navigationFailure(message: String, code: Int?)
    case subprocessRestart(message: String, code: Int?)
    case httpFailure(status: Int)
    case blankNoncommitted
}

enum EmbeddedBrowserSurfacePresentation {
    static func condition(
        for state: EmbeddedBrowserNavigationState
    ) -> EmbeddedBrowserSurfaceCondition {
        if let error = state.structuredError {
            switch error.kind {
            case .security:
                return .blockedBySecurity(message: error.message)
            case .navigation, .startup:
                return .navigationFailure(
                    message: error.message,
                    code: error.code)
            case .renderer:
                return .subprocessRestart(
                    message: error.message,
                    code: error.code)
            }
        }
        if state.phase == .blockedBySecurity {
            return .blockedBySecurity(
                message:
                    state.visibleError?.message
                        ?? "安全政策已封鎖這次導覽。")
        }
        if state.phase == .navigationFailed {
            return .navigationFailure(
                message:
                    state.visibleError?.message
                        ?? "頁面導覽失敗。",
                code: nil)
        }
        if state.phase == .rendererFailed {
            return .subprocessRestart(
                message:
                    state.visibleError?.message
                        ?? "Chromium renderer 已停止，正在等待安全重啟。",
                code: nil)
        }
        if let status = state.httpStatusCode, status >= 400 {
            return .httpFailure(status: status)
        }
        if state.phase == .finished,
           state.committedMainFrameURLString?.isEmpty == false
        {
            return .none
        }
        if state.phase == .creating
            || ((state.isLoading || state.phase == .loading)
                && state.committedMainFrameURLString?.isEmpty != false)
        {
            return .pageCreating
        }
        if state.phase == .committed && state.isLoading {
            return .loadedAwaitingPaint
        }
        if state.isLoading || state.phase == .loading {
            return .pageCreating
        }
        if state.committedMainFrameURLString?.isEmpty != false,
           state.phase != .closed
        {
            return .blankNoncommitted
        }
        return .none
    }
}
