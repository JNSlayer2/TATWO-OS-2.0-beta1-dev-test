import SwiftUI

/// Compatibility facade: existing Computer Use callers retain their Decision and cancellation API.
@MainActor
final class ComputerUseConsentPrompt: ObservableObject {
    static let shared = ComputerUseConsentPrompt()
    typealias Request = IslandNotice.Request
    typealias Decision = IslandNotice.Decision
    private var pendingIDs: Set<UUID> = []
    var current: Request? {
        guard let request = IslandNotice.shared.current, pendingIDs.contains(request.id) else { return nil }
        return request
    }
    var hostAvailable: Bool {
        get { IslandNotice.shared.hostAvailable }
        set { IslandNotice.shared.hostAvailable = newValue }
    }

    func ask(title: String, detail: String, allowLabel: String, timeout: TimeInterval) async -> Decision {
        let id = UUID()
        pendingIDs.insert(id)
        defer { pendingIDs.remove(id) }
        return await IslandNotice.shared.ask(title: title, detail: detail, allowLabel: allowLabel,
                                             timeout: timeout, requestID: id)
    }

    func resolve(_ decision: Decision) {
        // A Computer Use stop cannot dismiss an unrelated confirm/info card.
        if decision == .allow {
            if let current { IslandNotice.shared.resolve(decision, id: current.id) }
        } else {
            for id in pendingIDs { IslandNotice.shared.resolve(decision, id: id) }
        }
    }
}

enum ComputerUseIslandContentKind: Equatable {
    case collapsed, consent, blankTemplate

    static func select(isExpanded: Bool, hasPendingConsent: Bool) -> Self {
        guard isExpanded else { return .collapsed }
        return hasPendingConsent ? .consent : .blankTemplate
    }
}

/// Compatibility name for the shared notice surface; idle expanded content remains blank.
typealias ComputerUseIslandContent = IslandNoticeContent

struct IslandNoticeContent: View {
    @ObservedObject private var prompt = IslandNotice.shared
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

    private var lastShownByKey: [String: Date] = [:]

    func show(key: String, title: String, detail: String, seconds: TimeInterval = 7, throttle: TimeInterval = 300) {
        if let last = lastShownByKey[key], Date().timeIntervalSince(last) < throttle { return }
        lastShownByKey[key] = Date()
        IslandNotice.shared.info(title: title, detail: detail, duration: seconds)
    }

    func dismiss() {
        guard let request = IslandNotice.shared.current, request.kind == .info else { return }
        IslandNotice.shared.resolve(.cancel, id: request.id)
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
                if request.kind != .info {
                    Button { IslandNotice.shared.resolve(.allow, id: request.id) } label: {
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
                    Button { IslandNotice.shared.resolve(.cancel, id: request.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(consentColor(0x5E554E))
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.72), in: Circle())
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(request.cancelLabel)
                    .accessibilityLabel(request.cancelLabel)
                }
            }
            .padding(.bottom, 2)
        }
        .overlay(alignment: .bottom) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(request.deadline.timeIntervalSince(context.date).rounded(.up)))
                Text(request.kind == .info ? "\(left) 秒後收起" : "\(left) 秒後自動取消")
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
