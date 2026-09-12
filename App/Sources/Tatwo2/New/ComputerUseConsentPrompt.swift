import SwiftUI

/// Computer Use consent inside TATWO Island (approved design v4, 2026-09-11): invisible normally; when a
/// consent is needed the Island opens and shows this card.
/// TATWO's window is never brought forward. The Island shows nothing else (2026-09-11).
@MainActor
final class ComputerUseConsentPrompt: ObservableObject {
    static let shared = ComputerUseConsentPrompt()

    struct Request: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let detail: String
        let allowLabel: String
        let deadline: Date
    }
    enum Decision { case allow, cancel, timeout }

    @Published private(set) var current: Request?
    /// Set when the Island shell is created (TatwoIslandShellController).
    var hostAvailable = false
    private var continuation: CheckedContinuation<Decision, Never>?
    private var timeoutTask: Task<Void, Never>?

    func ask(title: String, detail: String, allowLabel: String, timeout: TimeInterval) async -> Decision {
        resolve(.cancel)   // never two prompts at once
        let request = Request(title: title, detail: detail, allowLabel: allowLabel,
                              deadline: Date().addingTimeInterval(timeout))
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            current = request
            IslandExceptionsNavigation.shell?.holdOpen(true)
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, self?.current?.id == request.id else { return }
                self?.resolve(.timeout)
            }
        }
    }

    func resolve(_ decision: Decision) {
        timeoutTask?.cancel(); timeoutTask = nil
        guard let continuation else { return }
        self.continuation = nil
        current = nil
        IslandExceptionsNavigation.shell?.holdOpen(false)
        continuation.resume(returning: decision)
    }
}

enum ComputerUseIslandContentKind: Equatable {
    case collapsed, consent, blankTemplate

    static func select(isExpanded: Bool, hasPendingConsent: Bool) -> Self {
        guard isExpanded else { return .collapsed }
        return hasPendingConsent ? .consent : .blankTemplate
    }
}

/// W8: pending consent takes priority; otherwise leave the expanded Island blank.
struct ComputerUseIslandContent: View {
    @ObservedObject private var prompt = ComputerUseConsentPrompt.shared
    let isExpanded: Bool

    var body: some View {
        switch ComputerUseIslandContentKind.select(
            isExpanded: isExpanded, hasPendingConsent: prompt.current != nil
        ) {
        case .consent:
            if let request = prompt.current {
                ComputerUseConsentCard(request: request)
            }
        case .blankTemplate:
            IslandBlankTemplate()
        case .collapsed:
            EmptyView()
        }
    }
}

/// Preserve the former work content's footprint; the shell supplies the glass.
struct IslandBlankTemplate: View {
    var body: some View {
        Color.clear
            .frame(width: 596, height: 124)
            .padding(.top, 36)
    }
}

/// A short, dismissible Island heads-up that is not a consent (no allow/deny). It opens the Island for a
/// few seconds then collapses. Throttled so it never spams. Used for the browser-profile capacity warning
/// (使用者：滿了自動清最久沒用的，提前 20 個時在 island 通知).
@MainActor
final class ComputerUseIslandNotice: ObservableObject {
    static let shared = ComputerUseIslandNotice()

    struct Message: Identifiable, Equatable { let id = UUID(); let title: String; let detail: String }

    @Published private(set) var current: Message?
    private var dismissTask: Task<Void, Never>?
    private var lastShownByKey: [String: Date] = [:]

    /// Show `title`/`detail` for `seconds`, at most once per `throttle` for the given `key`.
    func show(key: String, title: String, detail: String, seconds: TimeInterval = 7, throttle: TimeInterval = 300) {
        // Never cover a live consent prompt.
        guard ComputerUseConsentPrompt.shared.current == nil else { return }
        if let last = lastShownByKey[key], Date().timeIntervalSince(last) < throttle { return }
        lastShownByKey[key] = Date()
        current = Message(title: title, detail: detail)
        IslandExceptionsNavigation.shell?.holdOpen(true)
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel(); dismissTask = nil
        current = nil
        IslandExceptionsNavigation.shell?.holdOpen(false)
    }

    /// Browser independent-storage capacity: warn from `warnAt` up to `limit`; explain LRU auto-eviction.
    nonisolated static func browserCapacity(count: Int, limit: Int, warnAt: Int) {
        guard count >= warnAt else { return }
        Task { @MainActor in
            let title = count >= limit ? "瀏覽器獨立資料已滿（\(count)/\(limit)）"
                                       : "瀏覽器獨立資料快滿了（\(count)/\(limit)）"
            shared.show(key: "browser-capacity",
                        title: title,
                        detail: "滿了會自動清掉最久沒用、目前沒開著的那一份；很舊的聊天可能要重新登入。")
        }
    }
}

/// Island notice card (no allow/deny): TATWO arrow logo · title · one line · a single dismiss button.
struct ComputerUseNoticeCard: View {
    let message: ComputerUseIslandNotice.Message

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.55))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.05), radius: 7, y: 4)
                ComputerUseArrowGlyph(style: .aurora, spin: .zero)
                    .frame(width: 34, height: 38)
                    .offset(x: 4, y: 1.5)
            }
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(message.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(consentColor(0x2B2521))
                Text(message.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(consentColor(0x7B6F65))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button { ComputerUseIslandNotice.shared.dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(consentColor(0x5E554E))
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.72), in: Circle())
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("知道了")
            .accessibilityLabel("知道了")
        }
        .padding(.horizontal, 8)
        .frame(width: 596, height: 124)
        .padding(.top, 36)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.title)
    }
}

private func consentColor(_ value: UInt32, _ alpha: Double = 1) -> Color {
    Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
          blue: Double(value & 0xFF) / 255, opacity: alpha)
}

/// Logo (TATWO's own arrow) · title · one line · ✓ / ✕ round buttons at the bottom right · countdown.
struct ComputerUseConsentCard: View {
    let request: ComputerUseConsentPrompt.Request

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            HStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.55))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.05), radius: 7, y: 4)
                    // optical centre: the arrow's weight sits on its straight left edge
                    ComputerUseArrowGlyph(style: .aurora, spin: .zero)
                        .frame(width: 34, height: 38)
                        .offset(x: 4, y: 1.5)
                }
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(consentColor(0x2B2521))
                    Text(request.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(consentColor(0x7B6F65))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 96)
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 10) {
                Button { ComputerUseConsentPrompt.shared.resolve(.allow) } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(LiquidGlassTokens.brandAccent, in: Circle())
                        .shadow(color: LiquidGlassTokens.brandAccent.opacity(0.25), radius: 4, y: 3)
                }
                .buttonStyle(.plain)
                .help(request.allowLabel)
                .accessibilityLabel(request.allowLabel)
                Button { ComputerUseConsentPrompt.shared.resolve(.cancel) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(consentColor(0x5E554E))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.72), in: Circle())
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("取消")
                .accessibilityLabel("取消")
            }
            .padding(.bottom, 2)
        }
        .overlay(alignment: .bottom) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(request.deadline.timeIntervalSince(context.date).rounded(.up)))
                Text("\(left) 秒後自動取消")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(consentColor(0xA39889))
            }
            .padding(.bottom, 2)
        }
        .padding(.horizontal, 8)
        .frame(width: 596, height: 124)
        .padding(.top, 36)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(request.title)
    }
}
