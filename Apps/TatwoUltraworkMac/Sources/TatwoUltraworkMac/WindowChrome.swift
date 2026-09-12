import AppKit
import SwiftUI

enum WindowChromeMetrics {
    static let bandHeight: CGFloat = 34
    static let windowCornerRadius: CGFloat = 12
    static let trafficLightLeadingInset: CGFloat = 16
    static let trafficLightTopInset: CGFloat = 16
    static let nativeTrafficLightDiameter: CGFloat = 14
    static let nativeTrafficLightSpacing: CGFloat = 9
    static let headerHorizontalInset: CGFloat = 10
    /// Chat 頁內的三顆頂列控制（常駐鈕／資訊卡／工具組）從 safe area 抬進
    /// band，讓 26pt 高的鈕垂直置中於紅綠燈（top 16 + 14/2 = 23）。
    static let chromeRowLift: CGFloat = bandHeight - (trafficLightTopInset + nativeTrafficLightDiameter / 2 - 13)
    static let controlSpacing: CGFloat = 8

    /// Chat band 頂右讓位寬度：頁內 icon strip（資訊卡 + 瀏覽器/檔案）佔位，拖曳 NSView 必須讓出這塊，
    /// 否則 mouseDownCanMoveWindow 會吃掉 strip 點擊（2026-07-12 使用者「按鈕沒反應」根因）。
    static let chatRightControlsReserve: CGFloat = 130  // 3 顆 30pt 鈕 + 2×8 間距 + 14 內距 + 餘裕

    static let trafficLightClusterMaxX =
        trafficLightLeadingInset
        + (nativeTrafficLightDiameter * 3)
        + (nativeTrafficLightSpacing * 2)

    static let trafficLightSafeWidth = trafficLightClusterMaxX + headerHorizontalInset
    static let appControlLeadingX = trafficLightSafeWidth + controlSpacing

    static func trafficLightOrigin(index: Int, buttonSize: NSSize, containerHeight: CGFloat) -> NSPoint {
        NSPoint(
            x: trafficLightLeadingInset + CGFloat(index) * (nativeTrafficLightDiameter + nativeTrafficLightSpacing),
            y: max(0, containerHeight - trafficLightTopInset - buttonSize.height)
        )
    }
}

extension TatwoWorkOSWindow {
    func configureTatwoChrome() {
        styleMask.insert(.fullSizeContentView)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // 消除 .titled 視窗預設的 titlebar 分隔線（#23 頂部橫向色帶接縫的真凶）。
        titlebarSeparatorStyle = .none
        backgroundColor = .clear
        isOpaque = false
        isMovableByWindowBackground = false
        sealTatwoContentCorners()
        layoutIfNeeded()
        layoutTatwoTrafficLights()
    }

    func sealTatwoContentCorners() {
        guard let contentView else { return }
        // Full-size transparent hosting views are not reliably clipped by the
        // titled window frame, so square SwiftUI backdrops can leak at all four corners.
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.layer?.cornerRadius = WindowChromeMetrics.windowCornerRadius
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.masksToBounds = true
    }

    /// 視窗表面依主題二選一（2026-09-03 使用者：四角出現 90 度黑角）：
    /// - 玻璃主題（極光）：透明視窗＋自己遮圓角，behind-window 材質才取得到景。
    /// - 實底主題（fable5 牛皮紙）：**不透明**視窗、底色交給系統，圓角由系統畫，
    ///   與 Terminal／Codex 同一套半徑；透明視窗＋layer 遮罩在某些取景／螢幕共享
    ///   管線會把遮掉的角落當成未定義 alpha 畫成黑色方角，實底根本不需要那條路。
    func applyTatwoWindowSurface() {
        let palette = TatwoActivePalette.current
        if palette.usesGlass {
            backgroundColor = .clear
            isOpaque = false
            sealTatwoContentCorners()
        } else {
            backgroundColor = NSColor(palette.canvasBase)
            isOpaque = true
            if let contentView {
                contentView.wantsLayer = true
                contentView.layer?.backgroundColor = NSColor.clear.cgColor
                contentView.layer?.cornerRadius = 0
                contentView.layer?.masksToBounds = false
            }
        }
        invalidateShadow()
    }

    func layoutTatwoTrafficLights() {
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in buttonTypes.enumerated() {
            guard let button = standardWindowButton(type),
                  let container = button.superview
            else { continue }
            button.setFrameOrigin(
                WindowChromeMetrics.trafficLightOrigin(
                    index: index,
                    buttonSize: button.frame.size,
                    containerHeight: container.bounds.height
                )
            )
        }
    }
}

struct TatwoWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> TatwoWindowDragNSView {
        TatwoWindowDragNSView()
    }

    func updateNSView(_ nsView: TatwoWindowDragNSView, context: Context) {}
}

final class TatwoWindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
