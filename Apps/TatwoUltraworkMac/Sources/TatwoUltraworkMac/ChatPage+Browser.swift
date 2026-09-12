import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin
import TatwoUltraworkCore
import TatwoWorkReceiptContracts

enum BrowserPanelWidthPolicy {
    static let minimumWidth: CGFloat = 420
    static let minimumDefaultWidth: CGFloat = 480
    static let defaultWindowRatio: CGFloat = 0.42
    static let maximumWindowRatio: CGFloat = 0.72

    static func clamp(_ width: CGFloat, windowWidth: CGFloat) -> CGFloat {
        let maximumWidth = max(
            minimumWidth,
            max(0, windowWidth) * maximumWindowRatio)
        return min(max(width, minimumWidth), maximumWidth)
    }

    static func defaultWidth(windowWidth: CGFloat) -> CGFloat {
        clamp(
            max(
                max(0, windowWidth) * defaultWindowRatio,
                minimumDefaultWidth),
            windowWidth: windowWidth)
    }

    static func restoredWidth(
        persistedWidth: CGFloat,
        windowWidth: CGFloat
    ) -> CGFloat {
        guard persistedWidth.isFinite,
              persistedWidth >= minimumWidth
        else {
            return defaultWidth(windowWidth: windowWidth)
        }
        return clamp(persistedWidth, windowWidth: windowWidth)
    }

    static func needsLegacyWidthMigration(_ persistedWidth: CGFloat) -> Bool {
        !persistedWidth.isFinite || persistedWidth < minimumWidth
    }
}

enum BrowserPanelDragPolicy {
    static func previewWidth(
        persistedWidth: CGFloat,
        translation: CGFloat,
        windowWidth: CGFloat
    ) -> CGFloat {
        let restoredWidth = BrowserPanelWidthPolicy.restoredWidth(
            persistedWidth: persistedWidth,
            windowWidth: windowWidth)
        return BrowserPanelWidthPolicy.clamp(
            restoredWidth - translation,
            windowWidth: windowWidth)
    }
}

enum BrowserPanelResizeHandlePlacement: Equatable {
    case bottomLeading
}

struct BrowserPanelOverlayLayoutResult: Equatable {
    let isOpen: Bool
    let chatContentWidth: CGFloat
    let panelWidth: CGFloat
    let handlePlacement: BrowserPanelResizeHandlePlacement
}

enum BrowserPanelOverlayLayoutPolicy {
    static let handleSize: CGFloat = 24
    static let handleOffset = CGSize(width: -12, height: -12)
    // The full-size window content begins below this visual inset. Extending
    // the overlay upward by the measured 24pt makes the browser card flush
    // with the window top; the browser toolbar separately installs a
    // mouseDownCanMoveWindow=false host so titlebar dragging cannot steal taps.
    static let windowTopExtension: CGFloat = 24

    static func resolve(
        layoutWidth rawLayoutWidth: CGFloat,
        requestedWidth: CGFloat,
        isOpen: Bool
    ) -> BrowserPanelOverlayLayoutResult {
        let layoutWidth = max(0, rawLayoutWidth)
        return BrowserPanelOverlayLayoutResult(
            isOpen: isOpen,
            chatContentWidth: layoutWidth,
            panelWidth: isOpen
                ? BrowserPanelWidthPolicy.clamp(
                    requestedWidth,
                    windowWidth: layoutWidth)
                : 0,
            handlePlacement: .bottomLeading)
    }
}
