import SwiftUI

struct BrowserSettingsSectionHeading: View {
    let title: String
    let number: Int?

    var body: some View {
        HStack(spacing: BrowserSidebarMetrics.rowHorizontalPadding) {
            if let number {
                Text("\(number)")
                    .foregroundStyle(LiquidGlassTokens.browserSecondaryInk)
                    .font(.system(size: BrowserSidebarMetrics.settingsNumberFontSize))
                    .frame(width: BrowserSidebarMetrics.settingsNumberSize, height: BrowserSidebarMetrics.settingsNumberSize)
                    .background(LiquidGlassTokens.browserChipFill, in: Circle())
                    .accessibilityHidden(true)
            }
            Text(title).font(.system(size: BrowserSidebarMetrics.settingsTitleFontSize, weight: .semibold))
                .foregroundStyle(LiquidGlassTokens.browserInk)
        }
    }
}

struct BrowserSettingsControlStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: BrowserSidebarMetrics.settingsControlFontSize))
            .padding(.vertical, BrowserSidebarMetrics.settingsControlVerticalPadding)
            .padding(.horizontal, BrowserSidebarMetrics.settingsControlHorizontalPadding)
            .background(LiquidGlassTokens.browserChipFill,
                        in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.settingsControlRadius))
            .opacity(isEnabled ? BrowserSidebarMetrics.visibleOpacity : BrowserSidebarMetrics.settingsDisabledOpacity)
    }
}

/// Fixed key / flexible current value / intrinsic control, matching v10's kv grid.
struct BrowserSettingsKVRow<Control: View>: View {
    let title: String
    let value: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: BrowserSidebarMetrics.settingsColumnSpacing) {
            Text(title).foregroundStyle(LiquidGlassTokens.browserMutedInk)
                .frame(width: BrowserSidebarMetrics.settingsKeyWidth, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            control().labelsHidden()
                .font(.system(size: BrowserSidebarMetrics.settingsControlFontSize))
                .buttonStyle(.plain).menuStyle(.borderlessButton)
                .controlSize(.small)
                .padding(.vertical, BrowserSidebarMetrics.settingsControlVerticalPadding)
                .padding(.horizontal, BrowserSidebarMetrics.settingsControlHorizontalPadding)
                .background(LiquidGlassTokens.browserChipFill,
                            in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.settingsControlRadius))
        }
        .foregroundStyle(LiquidGlassTokens.browserInk)
        .font(.system(size: BrowserSidebarMetrics.settingsBodyFontSize))
        .environment(\.colorScheme, .light)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Read-only policy value. It is deliberately Text, not a disabled imitation of a working control.
struct BrowserSettingsPolicyValue: View {
    let value: String
    var body: some View {
        Text(value)
            .foregroundStyle(LiquidGlassTokens.browserSecondaryInk)
            .font(.system(size: BrowserSidebarMetrics.settingsControlFontSize))
            .padding(.vertical, BrowserSidebarMetrics.settingsControlVerticalPadding)
            .padding(.horizontal, BrowserSidebarMetrics.settingsControlHorizontalPadding)
            .background(LiquidGlassTokens.browserChipFill,
                        in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.settingsControlRadius))
            .opacity(BrowserSidebarMetrics.settingsDisabledOpacity)
            .allowsHitTesting(false)
    }
}
