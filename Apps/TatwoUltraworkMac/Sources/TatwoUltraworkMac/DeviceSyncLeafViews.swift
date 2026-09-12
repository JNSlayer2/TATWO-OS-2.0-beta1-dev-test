import SwiftUI
import TatwoUltraworkCore

struct DevicesSectionHeader: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let index: String
    let title: String
    var actionTitle: String? = nil
    var actionEnabled: Bool = true
    var onAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(index)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(LiquidGlassTokens.brandAccent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    LiquidGlassTokens.brandAccent.opacity(LiquidGlassTokens.chipFillOpacity),
                    in: Capsule()
                )
            Text(title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Spacer(minLength: 0)
            if let actionTitle, let onAction {
                Button(action: onAction) {
                    Text(actionTitle)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(LiquidGlassTokens.brandAccent)
                .disabled(!actionEnabled)
                .opacity(actionEnabled ? 0.72 : 0.40)
            }
        }
    }
}

struct DevicesInclusionPill: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            EmptyView()
        }
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .accessibilityLabel(isOn ? "納入本輪動作" : "不納入本輪動作")
        .accessibilityValue(isOn ? "開" : "關")
    }
}

struct DeviceIdentityCard: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let model: DevicesIdentityCardModel
    let transferPending: Bool
    let onTransferPrimary: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(model.displayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                localityChip
                Spacer(minLength: 4)
                Image(systemName: model.isPrimary ? "crown.fill" : "crown")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.isPrimary ? Color.yellow : Color.secondary)
                    .help(model.isPrimary ? "主設備" : "副設備")
                    .accessibilityLabel(model.isPrimary ? "主設備" : "副設備")
            }
            Text(model.hardwareLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .opacity(model.isInventoryStale ? 0.4 : 1)
            if let updated = model.inventoryUpdatedLabel {
                Text(updated)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                Text("App \(model.appVersion ?? DevicesPagePresentation.unknownVersion)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(model.connection.label)
                    .font(.caption2)
                    .foregroundStyle(connectionColor)
                Spacer(minLength: 4)
                if let onTransferPrimary {
                    Button(action: onTransferPrimary) {
                        if transferPending {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("轉移主權")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(LiquidGlassTokens.brandAccent)
                    .disabled(transferPending)
                    .opacity(0.72)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusChip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(model.displayName)，\(model.localityLabel)，\(model.isPrimary ? "主設備" : "副設備")，\(model.connection.label)"
        )
    }

    private var localityChip: some View {
        Text(model.localityLabel)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                LiquidGlassTokens.tint.opacity(LiquidGlassTokens.chipFillOpacity),
                in: Capsule()
            )
            .foregroundStyle(.secondary)
    }

    private var connectionColor: Color {
        switch model.connection {
        case .connected: .green
        case .syncing: LiquidGlassTokens.brandAccent
        case .offline: .orange
        case .unknown: .secondary
        }
    }
}

struct DeviceVersionRow: View {
    let model: DevicesVersionRowModel
    @Binding var isIncluded: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.deviceName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("App \(model.appVersion)  ·  head \(model.releaseHead)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let lastCheckLabel = model.lastCheckLabel {
                    Text(lastCheckLabel)
                        .font(.caption2)
                        .foregroundStyle(model.isFailed ? Color.red : Color.secondary.opacity(0.72))
                }
            }
            Spacer(minLength: 8)
            if model.isChecking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("\(model.deviceName) 更新中")
            } else {
                DevicesInclusionPill(isOn: $isIncluded)
            }
        }
        .padding(.vertical, 3)
    }
}

struct DeviceDataDeviceRow: View {
    let model: DevicesDataDeviceRowModel
    @Binding var isIncluded: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.deviceName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                if let statusLabel = model.statusLabel {
                    Text(statusLabel)
                        .font(.caption2)
                        .foregroundStyle(model.isFailed ? Color.red : Color.secondary.opacity(0.72))
                }
            }
            Spacer(minLength: 8)
            if model.isSyncing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("\(model.deviceName) 同步中")
            } else {
                DevicesInclusionPill(isOn: $isIncluded)
            }
        }
        .padding(.vertical, 3)
    }
}

struct DeviceCLIVersionInfoRow: View {
    let model: DevicesCLIVersionInfoModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.titleZh)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(model.plainZh)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text("尚無運輸")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.titleZh)，資訊列，尚無運輸")
    }
}

struct DeviceDataModuleRow: View {
    let model: DevicesDataModuleRowModel
    let isReasonExpanded: Bool
    let onToggle: (Bool) -> Void
    let onToggleReason: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.titleZh)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(model.plainZh)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .opacity(model.excluded ? 0.45 : 1)
                Spacer(minLength: 8)
                trailingControl
            }
            if isReasonExpanded, let reason = model.failureReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var trailingControl: some View {
        if model.excluded {
            Text(DevicesPagePresentation.threadsExclusionNote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else if model.isSyncing {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("\(model.titleZh) 同步中")
        } else {
            HStack(spacing: 8) {
                if model.isFailed {
                    Button(action: onToggleReason) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                    }
                    .buttonStyle(.plain)
                    .help(isReasonExpanded ? "收合失敗原因" : "顯示失敗原因")
                    .accessibilityLabel("同步失敗")
                }
                Toggle(isOn: Binding(
                    get: { model.enabled },
                    set: { newValue in onToggle(newValue) }
                )) {
                    EmptyView()
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(model.titleZh)
            }
        }
    }
}

struct DevicePressureMetricChip: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let label: String
    let value: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.tertiary)
            Text(value)
                .foregroundStyle(tint)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            LiquidGlassTokens.tint.opacity(LiquidGlassTokens.chipFillOpacity),
            in: Capsule()
        )
    }
}
