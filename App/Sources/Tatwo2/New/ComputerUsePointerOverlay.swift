import AppKit
import QuartzCore
import CoreImage

/// TATWO's own Computer Use pointer (design G6, approved 2026-09-11): a rounded liquid-glass arrow
/// with a slowly rotating aurora tint, a soft glow that follows the arrow's outline, and a glass
/// label naming the App being operated. It marks where TATWO is acting; it never takes mouse input.
///
/// Glass values come from LiquidGlassTokens (Liquid Glass Dashboard「玻璃 1」): white tint at 0.18,
/// shadow 0.04 / (0, 4) / 14. Distortion and chromatic aberration have no AppKit equivalent here and
/// are approximated by the system material, as elsewhere in TATWO.
@MainActor
final class ComputerUsePointerOverlay {
    static let shared = ComputerUsePointerOverlay()

    private static let arrowSize = CGSize(width: 34, height: 38)
    private static let inset: CGFloat = 16          // room for the glow blur and the shadow
    private static let tipInArrow = CGPoint(x: 4.9, y: 4.2)  // visual arrow tip, y down (rounder tip, 2026-09-11)
    /// 2026-09-11 使用者：整體微縮小。The content view draws in a bounds 1/0.88 larger than its frame.
    private static let scale: CGFloat = 0.88
    private var builtStyle: ComputerUseSettings.ArrowStyle?
    private static let panelSize = CGSize(width: 280, height: 84)

    private var panel: NSPanel?
    private var root: OverlayRootView?
    private var tracking: Timer?
    private var motion: Timer?
    /// 2026-09-11 使用者：「滑鼠抵達目標之前會錯動」— a batch sends a new point every ~120 ms while one
    /// glide lasts 0.32–0.7 s, so each glide was cut off mid-arc and restarted toward the next target
    /// (zig-zag). Points now queue: every glide finishes; queued ones run short (0.2 s) to keep up.
    private var queue: [(point: CGPoint, click: Bool)] = []
    private var activeUntil: TimeInterval = 0
    private var appName = ""
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The rounded arrow (same path as the approved mock), y-down, in a 34 x 38 box.
    static func arrowPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 4.50, y: 7.30))
        path.addLine(to: CGPoint(x: 4.50, y: 24.90)); path.addQuadCurve(to: CGPoint(x: 6.49, y: 25.83), control: CGPoint(x: 4.50, y: 27.50))
        path.addLine(to: CGPoint(x: 9.51, y: 23.31)); path.addQuadCurve(to: CGPoint(x: 12.14, y: 23.89), control: CGPoint(x: 11.20, y: 21.90))
        path.addLine(to: CGPoint(x: 14.49, y: 28.85)); path.addQuadCurve(to: CGPoint(x: 17.99, y: 30.19), control: CGPoint(x: 15.60, y: 31.20))
        path.addLine(to: CGPoint(x: 18.41, y: 30.01)); path.addQuadCurve(to: CGPoint(x: 19.66, y: 26.66), control: CGPoint(x: 20.80, y: 29.00))
        path.addLine(to: CGPoint(x: 17.47, y: 22.18)); path.addQuadCurve(to: CGPoint(x: 18.70, y: 20.08), control: CGPoint(x: 16.50, y: 20.20))
        path.addLine(to: CGPoint(x: 22.80, y: 19.85)); path.addQuadCurve(to: CGPoint(x: 23.43, y: 17.93), control: CGPoint(x: 25.60, y: 19.70))
        path.addLine(to: CGPoint(x: 8.27, y: 5.47)); path.addQuadCurve(to: CGPoint(x: 4.50, y: 7.30), control: CGPoint(x: 4.50, y: 2.50))
        path.closeSubpath()
        return path
    }

    // MARK: - Lifecycle driven by ComputerUseController

    func show(appName: String) {
        self.appName = appName
        let settings = ComputerUseSettings.shared
        guard settings.showArrow else { hide(); return }
        if panel == nil || builtStyle != settings.arrowStyle {
            panel?.orderOut(nil); panel = nil; root = nil
            build()
        }
        root?.setLabel("TATWO 操作中 · \(appName)")
        root?.applyMotion(active: false, reduceMotion: reduceMotion)
        move(to: NSEvent.mouseLocation, animated: false)
        panel?.orderFrontRegardless()
    }

    /// Put the pointer where TATWO is acting (screen point, AppKit bottom-left coordinates).
    func point(at location: CGPoint, label: String? = nil, click: Bool = false) {
        guard panel != nil else { return }
        if let label { root?.setLabel(label) }
        // 2026-09-11 使用者：不要點擊水波效果（arrival is shown by the glide alone).
        if reduceMotion {
            queue.removeAll()
            move(to: location, animated: false)
            return
        }
        queue.append((location, click))
        if queue.count > 8 { queue.removeFirst(queue.count - 8) }
        if motion == nil { playNext() }
    }

    /// While an action runs the glow brightens and the pointer follows the real cursor if the action
    /// had to use it (foreground fallback). Idle costs nothing: no timer runs.
    func beginActivity(label: String, followsSystemCursor: Bool) {
        guard panel != nil else { return }
        root?.setLabel(label)
        root?.applyMotion(active: true, reduceMotion: reduceMotion)
        activeUntil = .infinity
        guard followsSystemCursor, tracking == nil else { return }
        tracking = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func endActivity() {
        guard panel != nil else { return }
        activeUntil = ProcessInfo.processInfo.systemUptime + 0.5
        root?.setLabel("TATWO 操作中 · \(appName)")
        if tracking == nil { settle() }
    }

    func hide() {
        tracking?.invalidate(); tracking = nil
        motion?.invalidate(); motion = nil
        queue.removeAll()
        panel?.orderOut(nil)
    }

    /// Settings › Computer Use changed (arrow on/off, label on/off, style).
    func settingsChanged() {
        let settings = ComputerUseSettings.shared
        guard let panel else { return }
        guard settings.showArrow else { hide(); return }
        if builtStyle != settings.arrowStyle {
            let frame = panel.frame, visible = panel.isVisible
            panel.orderOut(nil); self.panel = nil; root = nil
            build()
            self.panel?.setFrame(frame, display: false)
            root?.setLabel("TATWO 操作中 · \(appName)")
            root?.applyMotion(active: false, reduceMotion: reduceMotion)
            if visible { self.panel?.orderFrontRegardless() }
        }
        root?.setLabelVisible(settings.showLabel)
    }

    /// 黑色尖頭（參考 Codex 的代理游標）: a rounded navigation dart, tip at the same hotspot as the arrow,
    /// symmetric about the tip's diagonal. Rounded polygon with quadratic corners (same as the settings mock).
    static func dartPath() -> CGPath {
        let points = [CGPoint(x: 4.5, y: 3), CGPoint(x: 25, y: 11.6), CGPoint(x: 15.4, y: 14), CGPoint(x: 13, y: 23.6)]
        let radii: [CGFloat] = [3.6, 3.4, 4.2, 3.4]
        var corners: [(CGPoint, CGPoint, CGPoint)] = []
        for i in points.indices {
            let p = points[i], a = points[(i + points.count - 1) % points.count], b = points[(i + 1) % points.count]
            let la = hypot(a.x - p.x, a.y - p.y), lb = hypot(b.x - p.x, b.y - p.y)
            let r = min(radii[i], la / 2, lb / 2)
            corners.append((CGPoint(x: p.x + (a.x - p.x) * r / la, y: p.y + (a.y - p.y) * r / la), p,
                            CGPoint(x: p.x + (b.x - p.x) * r / lb, y: p.y + (b.y - p.y) * r / lb)))
        }
        let path = CGMutablePath()
        path.move(to: corners[0].2)
        for i in 1...corners.count {
            let corner = corners[i % corners.count]
            path.addLine(to: corner.0)
            path.addQuadCurve(to: corner.2, control: corner.1)
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Internals

    private func tick() {
        move(to: NSEvent.mouseLocation, animated: false)
        if ProcessInfo.processInfo.systemUptime > activeUntil {
            tracking?.invalidate(); tracking = nil
            settle()
        }
    }

    private func settle() {
        root?.applyMotion(active: false, reduceMotion: reduceMotion)
    }

    private func move(to location: CGPoint, animated: Bool, completion: (() -> Void)? = nil) {
        guard let panel else { return }
        // The tip sits at (inset + tip.x, inset + tip.y) in the y-down content view.
        let tipX = (Self.inset + Self.tipInArrow.x) * Self.scale, tipYDown = (Self.inset + Self.tipInArrow.y) * Self.scale
        let origin = CGPoint(x: location.x - tipX, y: location.y + tipYDown - Self.panelSize.height)
        let frame = CGRect(origin: origin, size: Self.panelSize)
        if animated {
            glide(to: frame.origin, completion: completion)
        } else {
            motion?.invalidate(); motion = nil
            queue.removeAll()
            panel.setFrame(frame, display: false)
            completion?()
        }
    }

    /// 2026-09-11 使用者：軌跡要像 Codex——走一段弧線、越接近目標越慢（ease-out quart）。
    /// The panel travels a quadratic curve that bows upward (bow ≤ 90pt, ~22% of the distance);
    /// 0.32–0.7 s depending on distance. A new target restarts from wherever the pointer is.
    private func playNext() {
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        move(to: next.point, animated: true) { [weak self] in
            self?.playNext()
        }
    }

    private func glide(to end: CGPoint, completion: (() -> Void)?) {
        guard let panel else { return }
        motion?.invalidate(); motion = nil
        let start = panel.frame.origin
        let dx = end.x - start.x, dy = end.y - start.y, dist = hypot(dx, dy)
        guard dist > 2 else { panel.setFrameOrigin(end); completion?(); return }
        var nx = -dy / dist, ny = dx / dist
        if ny < 0 { nx = -nx; ny = -ny }
        let bow = min(90, dist * 0.22)
        let control = CGPoint(x: (start.x + end.x) / 2 + nx * bow, y: (start.y + end.y) / 2 + ny * bow)
        let duration = queue.isEmpty ? min(0.7, max(0.32, 0.26 + Double(dist) / 1800)) : 0.2
        let began = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { timer.invalidate(); return }
                let raw = min(1, (ProcessInfo.processInfo.systemUptime - began) / duration)
                let t = CGFloat(1 - pow(1 - raw, 4))
                let u = 1 - t
                panel.setFrameOrigin(CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                                             y: u * u * start.y + 2 * u * t * control.y + t * t * end.y))
                if raw >= 1 {
                    timer.invalidate(); self.motion = nil
                    completion?()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        motion = timer
    }

    private func build() {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.setAccessibilityElement(false)
        // Our observations capture only the target window (SCContentFilter desktopIndependentWindow),
        // so the pointer never enters the model's screenshots; screen recordings still show it.
        let style = ComputerUseSettings.shared.arrowStyle
        let root = OverlayRootView(frame: CGRect(origin: .zero, size: Self.panelSize),
                                   arrowOrigin: CGPoint(x: Self.inset, y: Self.inset), style: style)
        root.setBoundsSize(CGSize(width: Self.panelSize.width / Self.scale, height: Self.panelSize.height / Self.scale))
        root.setLabelVisible(ComputerUseSettings.shared.showLabel)
        builtStyle = style
        root.setAccessibilityElement(false)
        panel.contentView = root
        self.panel = panel
        self.root = root
    }
}

/// y-down layer tree: glow (behind) → glass (system material masked to the arrow) → tint + rim → label.
private final class OverlayRootView: NSView {
    override var isFlipped: Bool { true }
    private let arrowOrigin: CGPoint
    private let glow = CAGradientLayer()
    private let tintContainer = CALayer()
    private let tint = CAGradientLayer()
    private let rim = CAGradientLayer()
    private let ring = CAShapeLayer()
    private let label = NSTextField(labelWithString: "")
    private let pill = NSVisualEffectView()
    private let pillTint = CALayer()
    private let pillRim = CAGradientLayer()
    private let pillShadow = CAShapeLayer()
    private var active = false
    private let style: ComputerUseSettings.ArrowStyle

    init(frame: CGRect, arrowOrigin: CGPoint, style: ComputerUseSettings.ArrowStyle) {
        self.arrowOrigin = arrowOrigin
        self.style = style
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        let path = ComputerUsePointerOverlay.arrowPath()
        let box = CGRect(origin: arrowOrigin, size: CGSize(width: 34, height: 38))

        // Soft glow: same outline, blurred once into a mask; only opacity and colors animate.
        glow.frame = box.insetBy(dx: -10, dy: -10)
        glow.colors = Self.glowColors(shift: false)
        glow.startPoint = CGPoint(x: 0, y: 0); glow.endPoint = CGPoint(x: 1, y: 1)
        let glowMask = CALayer()
        glowMask.frame = glow.bounds
        glowMask.contents = Self.blurredMask(path: path, size: glow.bounds.size, offset: CGPoint(x: 10, y: 10), radius: 3.4)
        glow.mask = glowMask
        glow.opacity = 0.5   // 2026-09-11 使用者：泛光不明顯 → 加強
        let back = FlippedLayerView(frame: bounds)
        addSubview(back)
        back.layer?.addSublayer(glow)

        // Shadow per LiquidGlassTokens (0.04 / 0,4 / 14) plus a faint wide lift.
        let shadow = CAShapeLayer()
        shadow.frame = box; shadow.path = path; shadow.fillColor = NSColor.clear.cgColor
        shadow.shadowPath = path; shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = Float(LiquidGlassTokens.shadowOpacity + 0.09)
        shadow.shadowRadius = 5; shadow.shadowOffset = CGSize(width: 0, height: 3)
        back.layer?.addSublayer(shadow)

        // Glass: the system behind-window material, masked to the arrow, with the Dashboard white tint.
        let glass = NSVisualEffectView(frame: box)
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .aqua)
        glass.maskImage = Self.maskImage(path: path, size: box.size)
        addSubview(glass)
        let front = FlippedLayerView(frame: bounds)
        addSubview(front)
        let whiteTint = CAShapeLayer()
        whiteTint.frame = box; whiteTint.path = path
        whiteTint.fillColor = NSColor.white.withAlphaComponent(LiquidGlassTokens.tintOpacity).cgColor
        front.layer?.addSublayer(whiteTint)

        // Aurora tint: a conic gradient larger than the arrow, rotated slowly, masked to the arrow.
        tintContainer.frame = box
        let tintMask = CAShapeLayer(); tintMask.path = path
        tintContainer.mask = tintMask
        tint.type = .conic
        tint.colors = [NSColor(srgbHex: 0xF2A6D3), NSColor(srgbHex: 0xA98BF0), NSColor(srgbHex: 0x7FB0FF),
                       NSColor(srgbHex: 0xF2A6D3)].map(\.cgColor)
        tint.startPoint = CGPoint(x: 0.4, y: 0.45); tint.endPoint = CGPoint(x: 0.4, y: 0)
        tint.frame = CGRect(x: -23, y: -21, width: 80, height: 80)
        tint.opacity = 0.62
        if style == .clear {
            // 清透玻璃 (G1): a faint static aurora wash, no rotating tint, no glow.
            tint.type = .axial
            tint.colors = [NSColor(srgbHex: 0xEFC5E0), NSColor(srgbHex: 0xC1AEF2), NSColor(srgbHex: 0xAAC7FF)].map(\.cgColor)
            tint.startPoint = CGPoint(x: 0, y: 0); tint.endPoint = CGPoint(x: 1, y: 1)
            tint.frame = CGRect(origin: .zero, size: box.size)
            tint.opacity = 0.22
            glow.isHidden = true
        }
        tintContainer.addSublayer(tint)
        front.layer?.addSublayer(tintContainer)

        // Rim: a 1 pt translucent gradient light edge, softened (no dark outline).
        rim.frame = box
        // 2026-09-11 使用者：白邊太銳利 → 柔和的白色漸層。
        rim.colors = [NSColor.white.withAlphaComponent(0.95), NSColor.white.withAlphaComponent(0.55),
                      NSColor.white.withAlphaComponent(0.22)].map(\.cgColor)
        rim.startPoint = CGPoint(x: 0, y: 0); rim.endPoint = CGPoint(x: 1, y: 1)
        let rimMask = CAShapeLayer(); rimMask.path = path
        rimMask.fillColor = NSColor.clear.cgColor; rimMask.strokeColor = NSColor.black.cgColor; rimMask.lineWidth = 1.5; rimMask.lineJoin = .round
        rim.mask = rimMask
        rim.opacity = 1
        rim.shadowColor = NSColor.white.cgColor; rim.shadowOpacity = 0.6; rim.shadowRadius = 0.6; rim.shadowOffset = .zero
        front.layer?.addSublayer(rim)

        if style == .dart {
            // 黑色尖頭: black body, soft round white outline and halo, neutral shadow (no glass, no warm glow).
            back.isHidden = true; glass.isHidden = true
            whiteTint.isHidden = true; tintContainer.isHidden = true; rim.isHidden = true
            let dart = ComputerUsePointerOverlay.dartPath()
            let halo = CAShapeLayer()
            halo.frame = box; halo.path = dart
            halo.fillColor = NSColor.white.cgColor; halo.strokeColor = NSColor.white.cgColor
            halo.lineWidth = 3.2; halo.lineJoin = .round
            halo.shadowColor = NSColor.black.cgColor; halo.shadowOpacity = 0.2; halo.shadowRadius = 3
            halo.shadowOffset = CGSize(width: 0, height: 1.5)
            let bright = CAShapeLayer()
            bright.frame = box; bright.path = dart; bright.fillColor = NSColor.white.cgColor
            bright.shadowColor = NSColor.white.cgColor; bright.shadowOpacity = 0.9; bright.shadowRadius = 4; bright.shadowOffset = .zero
            let body = CAShapeLayer()
            body.frame = box; body.path = dart; body.fillColor = NSColor(srgbHex: 0x111111).cgColor
            front.layer?.addSublayer(bright); front.layer?.addSublayer(halo); front.layer?.addSublayer(body)
        }

        // Click ripple (kept for API compatibility; not played — 2026-09-11 使用者：不要點擊水波).
        ring.frame = CGRect(x: box.minX + 4.5 - 22, y: box.minY + 3 - 22, width: 44, height: 44)
        ring.path = CGPath(ellipseIn: ring.bounds, transform: nil)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = NSColor(srgbHex: 0xC1AEF2).withAlphaComponent(0.8).cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        front.layer?.addSublayer(ring)

        // Label pill: same glass, aurora hairline, names the App being operated.
        pill.material = .popover
        pill.blendingMode = .behindWindow
        pill.state = .active
        pill.appearance = NSAppearance(named: .aqua)
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 12
        pill.layer?.masksToBounds = true
        // 2026-09-11 使用者：操作中標籤改液態玻璃。Dashboard「玻璃 1」白 tint 0.18、陰影 0.04 (0,4) 14，
        // 柔和白色漸層光邊（與箭頭同一套）。
        pillTint.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        pill.layer?.addSublayer(pillTint)
        pillRim.colors = [NSColor.white.withAlphaComponent(0.95), NSColor.white.withAlphaComponent(0.5),
                          NSColor.white.withAlphaComponent(0.2)].map(\.cgColor)
        pillRim.startPoint = CGPoint(x: 0, y: 0); pillRim.endPoint = CGPoint(x: 1, y: 1)
        pill.layer?.addSublayer(pillRim)
        pillShadow.fillColor = NSColor.white.withAlphaComponent(0.01).cgColor
        pillShadow.shadowColor = NSColor.black.cgColor; pillShadow.shadowOpacity = 0.14
        pillShadow.shadowRadius = 8; pillShadow.shadowOffset = CGSize(width: 0, height: 4)
        back.layer?.addSublayer(pillShadow)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor(srgbHex: 0x231E36)
        label.lineBreakMode = .byTruncatingTail
        pill.addSubview(label)
        addSubview(pill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setLabel(_ text: String) {
        label.stringValue = text
        label.sizeToFit()
        let width = min(230, label.frame.width + 22)
        pill.frame = CGRect(x: arrowOrigin.x + 24, y: arrowOrigin.y + 30, width: width, height: 24)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pillTint.frame = pill.bounds
        pillRim.frame = pill.bounds
        let rimShape = CAShapeLayer()
        rimShape.path = CGPath(roundedRect: pill.bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 11.5, cornerHeight: 11.5, transform: nil)
        rimShape.fillColor = NSColor.clear.cgColor; rimShape.strokeColor = NSColor.black.cgColor; rimShape.lineWidth = 1
        pillRim.mask = rimShape
        pillShadow.frame = pill.frame
        pillShadow.path = CGPath(roundedRect: CGRect(origin: .zero, size: pill.frame.size), cornerWidth: 12, cornerHeight: 12, transform: nil)
        CATransaction.commit()
        label.frame = CGRect(x: 11, y: (24 - label.frame.height) / 2, width: width - 22, height: label.frame.height)
    }

    func setLabelVisible(_ visible: Bool) {
        pill.isHidden = !visible
        pillShadow.isHidden = !visible
    }

    func applyMotion(active: Bool, reduceMotion: Bool) {
        self.active = active
        tint.removeAllAnimations(); glow.removeAllAnimations()
        guard style == .aurora else { return }
        guard !reduceMotion else { glow.opacity = 0.5; return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0; spin.toValue = 2 * Double.pi
        spin.duration = 6; spin.repeatCount = .infinity
        tint.add(spin, forKey: "spin")
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = active ? 0.60 : 0.42; breathe.toValue = active ? 0.85 : 0.68
        breathe.duration = active ? 0.7 : 1.7; breathe.autoreverses = true; breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(breathe, forKey: "breathe")
        let hue = CABasicAnimation(keyPath: "colors")
        hue.fromValue = Self.glowColors(shift: false); hue.toValue = Self.glowColors(shift: true)
        hue.duration = active ? 3 : 7; hue.autoreverses = true; hue.repeatCount = .infinity
        glow.add(hue, forKey: "hue")
    }

    func ripple(reduceMotion: Bool) {
        guard !reduceMotion else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 0.3; scale.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
        let group = CAAnimationGroup(); group.animations = [scale, fade]; group.duration = 0.46
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
        ring.add(group, forKey: "ripple")
    }

    private static func glowColors(shift: Bool) -> [CGColor] {
        (shift ? [0xB9A2FF, 0x7FB0FF, 0x9CC8FF] : [0xF4A9D6, 0xA98BF0, 0x7FB0FF]).map { NSColor(srgbHex: $0).cgColor }
    }

    private static func maskImage(path: CGPath, size: CGSize) -> NSImage {
        NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(path); context.setFillColor(NSColor.black.cgColor); context.fillPath()
            return true
        }
    }

    /// Rendered once per launch: the arrow's alpha, blurred, as a mask image for the glow layer.
    private static func blurredMask(path: CGPath, size: CGSize, offset: CGPoint, radius: CGFloat) -> CGImage? {
        let scale: CGFloat = 2
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: offset.x, y: size.height - offset.y)
        context.scaleBy(x: 1, y: -1)
        context.addPath(path); context.setFillColor(NSColor.black.cgColor); context.fillPath()
        guard let sharp = context.makeImage() else { return nil }
        let input = CIImage(cgImage: sharp).clampedToExtent()
        let blurred = input.applyingGaussianBlur(sigma: Double(radius * scale)).cropped(to: CIImage(cgImage: sharp).extent)
        return CIContext().createCGImage(blurred, from: blurred.extent)
    }
}

/// A plain y-down layer host; keeps its sublayers in view order relative to sibling views.
private final class FlippedLayerView: NSView {
    override var isFlipped: Bool { true }
    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private extension NSColor {
    convenience init(srgbHex hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
