import SwiftUI

/// Uses the same visual controls as Chat, with domain-local fixture actions only.
/// Menus demonstrate choices; they do not grant permission or configure an engine.
struct SpaceSetupComposerToolbar: View {
    @ObservedObject var domain: SpaceSetupPreviewState.Domain
    let compact: Bool

    var body: some View {
        ChatComposerToolbarRow(compact: compact) {
            Menu {
                Button("貼上剪貼簿圖片", systemImage: "doc.on.clipboard") { previewOnly("貼上圖片") }
                Button("附加檔案…", systemImage: "paperclip") { previewOnly("附加檔案") }
                Button("連接 iPad…", systemImage: "ipad") { previewOnly("連接 iPad") }
                Divider()
                Button("搜尋對話…", systemImage: "magnifyingglass") { previewOnly("搜尋對話") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help(domain.isProduction ? "搭建需求目前使用文字輸入" : "加入內容：UI 預覽，不讀取檔案或剪貼簿")
            .disabled(domain.isProduction)

            Menu {
                ForEach(TatwoPermissionPreset.allCases) { preset in
                    Button {
                        domain.composerPermission = preset
                    } label: {
                        Label(preset.displayName, systemImage: domain.composerPermission == preset
                              ? "checkmark.circle.fill" : "circle")
                    }
                    .help(preset.subtitle)
                }
                Divider()
                if !domain.isProduction { Text("UI 預覽，不變更實際權限") }
            } label: {
                ChatComposerPermissionLabel(
                    symbol: permissionSymbol,
                    title: domain.isProduction && !domain.chosenBotID.isEmpty
                        ? "沿用 Bot" : domain.composerPermission.shortDisplayName,
                    tint: permissionTint)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: true, vertical: false)
            .controlSize(.small)
            .disabled(domain.isProduction && !domain.chosenBotID.isEmpty)

            Spacer(minLength: compact ? 8 : 14)
            HStack(spacing: compact ? 5 : 6) {
                modelMenu.disabled(domain.isProduction && !domain.chosenBotID.isEmpty)
                Menu {
                    ForEach(ChatCollaborationLevel.allCases) { level in
                        Button {
                            domain.composerCollaboration = level
                        } label: {
                            Label(level.title, systemImage: domain.composerCollaboration == level
                                  ? "checkmark.circle.fill" : "circle")
                        }
                    }
                    Divider()
                    Text("UI 預覽，不啟動協作任務")
                } label: {
                    ChatComposerCollaborationLabel(
                        compact: compact, active: domain.composerCollaboration != .off,
                        level: domain.composerCollaboration.title, selected: false)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(domain.isProduction)
            }
            .frame(width: ChatComposerModelLabel.width(compact: true)
                   + ChatComposerCollaborationLabel.width(compact: compact)
                   + (compact ? 5 : 6), height: 24, alignment: .trailing)

            ChatComposerSendButton(enabled: domain.canPreview) { domain.previewResult() }
                .accessibilityLabel(domain.isProduction ? "送出搭建需求" : "預覽搭建後動線，不送出訊息")
                .help(domain.isProduction ? "送出至此 Space 的搭建對話" : "預覽搭建後動線，不會真正送出")
        }
    }

    private var modelMenu: some View {
        Menu {
            ForEach(ChatRouteChoice.all) { route in
                Button {
                    domain.selectComposerRoute(route.id)
                } label: {
                    Label(route.title, systemImage: domain.composerRoute.id == route.id
                          ? "checkmark.circle.fill" : "circle")
                }
            }
            if !domain.isProduction && domain.composerRoute.supportsNativeReasoningControl {
                Divider()
                Menu("推理強度") {
                    ForEach(domain.composerRoute.allowedEfforts) { effort in
                        Button(effort.displayName) { domain.composerEffort = effort }
                    }
                }
            }
            if !domain.isProduction && domain.composerRoute.supportsNativeSpeedControl {
                Divider()
                Menu("速度") {
                    ForEach(domain.composerRoute.allowedSpeedTiers) { speed in
                        Button(speed.displayName) { domain.composerSpeed = speed }
                    }
                }
            }
            if !domain.isProduction {
                Divider()
                Text("UI 預覽，不連接模型或變更 Bot")
            }
        } label: {
            ChatComposerModelLabel(
                title: domain.isProduction && !domain.chosenBotID.isEmpty ? "Bot 設定"
                    : domain.composerRoute.title.replacingOccurrences(of: "GPT-", with: ""),
                suffix: domain.isProduction ? nil : domain.composerRoute.supportsNativeSpeedControl
                    ? domain.composerSpeed?.compactDisplayName
                    : (domain.composerRoute.supportsNativeReasoningControl
                       ? domain.composerEffort.compactDisplayName : nil),
                compact: true, selected: false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .controlSize(.small)
    }

    private var permissionSymbol: String {
        switch domain.composerPermission {
        case .askFirst: "hand.raised"
        case .approveForMe: "checkmark.bubble"
        case .fullAccess: "exclamationmark.shield"
        case .configFile: "gearshape"
        }
    }

    private var permissionTint: Color {
        switch domain.composerPermission {
        case .fullAccess: Color.red.opacity(0.88)
        case .approveForMe: Color.orange.opacity(0.86)
        case .askFirst, .configFile: Color.secondary
        }
    }

    private func previewOnly(_ action: String) {
        domain.validationMessage = "\(action)尚未接線；未讀取資料或呼叫服務。"
    }
}
