import SwiftUI

/// Uses the existing sidebar's visibility lifecycle; it does not pin or expand the sidebar.
struct BrowserFavoritesStrip: View {
    @ObservedObject var store: BrowserWorkSpaceStore
    @State private var targeted = false
    private let iconSize: CGFloat = 28

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BrowserSidebarMetrics.rowSpacing) {
                if store.registry.favorites.isEmpty {
                    Text("拖分頁到這裡珍藏")
                        .font(.system(size: BrowserSidebarMetrics.metaFontSize))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("browser.favorites.empty")
                }
                ForEach(store.registry.favorites) { favorite in
                    Button { store.openFavorite(favorite.id) } label: {
                        Group {
                            if let data = favorite.faviconPNG, let image = NSImage(data: data) {
                                Image(nsImage: image).resizable().scaledToFit()
                            } else {
                                Image(systemName: "globe")
                                    .foregroundStyle(LiquidGlassTokens.browserInk)
                            }
                        }
                        .frame(width: BrowserSidebarMetrics.workspaceFaviconSize,
                               height: BrowserSidebarMetrics.workspaceFaviconSize)
                        .frame(width: iconSize, height: iconSize)
                        .background(LiquidGlassTokens.browserFieldFill,
                                    in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.rowCornerRadius))
                        .contentShape(RoundedRectangle(cornerRadius: BrowserSidebarMetrics.rowCornerRadius))
                    }
                    .buttonStyle(.plain)
                    .help(favorite.title)
                    .accessibilityLabel(favorite.title)
                    .accessibilityIdentifier("browser.favorite.\(favorite.id)")
                    .contextMenu {
                        Button("移出珍藏") { store.registry.removeFavorite(favorite.id) }
                        Button("移到最前") { store.registry.moveFavorite(favorite.id, before: store.registry.favorites.first?.id) }
                            .disabled(favorite.order == 0)
                        Button("移到最後") { store.registry.moveFavorite(favorite.id, before: nil) }
                            .disabled(favorite.order == store.registry.favorites.count - 1)
                    }
                    .onDrag { NSItemProvider(object: "tatwo-browser-favorite:\(favorite.id)" as NSString) }
                    .dropDestination(for: String.self) { payloads, _ in
                        accept(payloads, before: favorite.id)
                    }
                }
                // A tail target also allows dropping after the final icon.
                Color.clear.frame(width: BrowserSidebarMetrics.rowHorizontalPadding, height: iconSize)
            }
            .padding(.horizontal, BrowserSidebarMetrics.rowHorizontalPadding)
            .frame(height: iconSize + 2 * BrowserSidebarMetrics.rowHorizontalPadding)
        }
        .frame(height: iconSize + 2 * BrowserSidebarMetrics.rowHorizontalPadding)
        .background(targeted ? LiquidGlassTokens.browserFieldFill : .clear,
                    in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.rowCornerRadius))
        .contentShape(Rectangle())
        .accessibilityIdentifier("browser.favorites.strip")
        .dropDestination(for: String.self) { payloads, _ in accept(payloads, before: nil) }
            isTargeted: { targeted = $0 }
        .contextMenu {
            Button("匯入珍藏 HTML…") { BrowserBookmarkExport.presentFavoriteImport(registry: store.registry) }
        }
    }

    private func accept(_ payloads: [String], before target: UUID?) -> Bool {
        BrowserFavoriteDrop.accept(payloads, before: target, registry: store.registry) { alias in
            store.tabs.first { $0.id == alias }?.registryID
        }
    }
}

/// The same action is used by bookmark and tab context menus.
struct BrowserFavoriteMenu: View {
    @ObservedObject var registry: BrowserTabRegistry
    let url: URL?
    let add: () -> Void
    var body: some View {
        if let url, let existing = registry.favorite(for: url) {
            Button("移出珍藏") { registry.removeFavorite(existing.id) }
        } else {
            Button("加入珍藏", action: add).disabled(url == nil)
        }
    }
}

@MainActor
enum BrowserFavoriteDrop {
    /// IDs must resolve in this registry/window. Never interpret dropped text as a URL.
    static func accept(_ payloads: [String], before target: UUID?, registry: BrowserTabRegistry,
                       tabID: (Int) -> UUID?) -> Bool {
        var accepted = false
        for payload in payloads {
            let parts = payload.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = String(parts[1])
            if parts[0] == "tatwo-browser-favorite", let id = UUID(uuidString: value) {
                if id == target { accepted = registry.favorites.contains { $0.id == id } || accepted }
                else { accepted = registry.moveFavorite(id, before: target) || accepted }
                continue
            }
            let favorite: BrowserFavorite?
            switch String(parts[0]) {
            case "tatwo-browser-tab":
                favorite = Int(value).flatMap(tabID).flatMap { registry.addFavorite(tabID: $0) }
            case "tatwo-browser-registry-tab":
                favorite = UUID(uuidString: value).flatMap { registry.addFavorite(tabID: $0) }
            case "tatwo-browser-bookmark":
                favorite = UUID(uuidString: value).flatMap { registry.addFavorite(bookmarkID: $0) }
            default: favorite = nil
            }
            if let favorite {
                if let target { registry.moveFavorite(favorite.id, before: target) }
                accepted = true
            }
        }
        return accepted
    }
}
