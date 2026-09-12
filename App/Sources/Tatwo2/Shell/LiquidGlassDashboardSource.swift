// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/LiquidGlassDashboardSource.swift；改動 1 行（原因：run A 照搬，僅移除舊水電 import／呼叫並接同名 Facade）
import SwiftUI

/// Source-anchored Liquid Glass bridge for native SwiftUI surfaces.
///
/// Source of truth (logical; no private absolute paths):
/// - Dashboard CLI: liquid-glass-dashboard skill 的 `lgd selected` 入口
/// - Warehouse renderer: Liquid Glass Dashboard 本機安裝位置，見 docs
/// - Current renderer file sha256:
///   `f1b756e479bddec40c0393996023203cc3ede625a9aeab174c8b9a5a5b13060c`
///
/// Native degradation boundary:
/// SwiftUI cannot run the warehouse WebGL `SourceGlassRenderer` fragment shader
/// inside a small popover control without embedding a WebView/Metal renderer.
/// This bridge therefore ports the *warehouse code math and exported layer
/// values* used for alpha/rim/shadow, while leaving shader-only refraction,
/// blur sampling, and chromatic aberration as documented degradation.
