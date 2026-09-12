#if os(macOS)
import CoreGraphics
import SwiftUI
import WebKit

final class LiquidGlassDashboardHitTransparentWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

class LiquidGlassDashboardSliderPointerCaptureView: NSView {
    var onBegan: ((CGFloat) -> Void)?
    var onChanged: ((CGFloat) -> Void)?
    var onEnded: ((CGFloat) -> Void)?
    private var isTrackingPointer = false
    private var diagnosticTrackingArea: NSTrackingArea?
    private var completedDiagnosticProbePhases: Set<String> = []
    private let debugSource: String
    private static let attachProbeThreadKey = "tatwo.slider.attach-probe"
    private static let pointerDiagnosticsEnabled =
        ProcessInfo.processInfo.environment["TATWO_SLIDER_POINTER_DEBUG"] == "1"

    init(debugSource: String) {
        self.debugSource = debugSource
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layer?.drawsAsynchronously = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let result: NSView? = capturesPointerInput && bounds.contains(point) ? self : nil
        debugLog(
            "hit-test",
            point: point,
            extra: "attachProbe=\(Self.attachProbeInProgress) result=\(debugViewDescription(result))"
        )
        return result
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        debugLog(
            "will-move-to-window",
            extra: "newWindow=\(debugWindowDescription(newWindow))"
        )
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        debugLog(
            "did-move-to-window",
            extra: "window=\(debugWindowDescription(window)) hierarchy=\(debugSuperviewChain())"
        )
        debugAttachTimeEvidence(phase: "did-move-to-window")
    }

    override func layout() {
        super.layout()
        debugLog(
            "layout",
            extra: "windowFrame=\(NSStringFromRect(window?.frame ?? .zero)) hierarchy=\(debugSuperviewChain())"
        )
        debugAttachTimeEvidence(phase: "layout")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let diagnosticTrackingArea {
            removeTrackingArea(diagnosticTrackingArea)
            self.diagnosticTrackingArea = nil
        }
        guard Self.pointerDiagnosticsEnabled else { return }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        diagnosticTrackingArea = area
        debugLog("tracking-area-installed", extra: "bounds=\(NSStringFromRect(bounds))")
    }

    override func mouseEntered(with event: NSEvent) {
        debugResolvedTarget(for: event, source: "mouse-entered")
    }

    override func mouseMoved(with event: NSEvent) {
        debugResolvedTarget(for: event, source: "mouse-moved")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    private var capturesPointerInput: Bool {
        onBegan != nil || onChanged != nil || onEnded != nil
    }

    private static var attachProbeInProgress: Bool {
        Thread.current.threadDictionary[attachProbeThreadKey] as? Bool == true
    }

    // Keep the hit-tested AppKit view as the mouse target for the normal
    // down/drag/up sequence without gesture-recognizer arbitration or a
    // blocking event loop.
    override func mouseDown(with event: NSEvent) {
        guard capturesPointerInput else { return }
        window?.makeFirstResponder(self)
        let x = localX(for: event)
        isTrackingPointer = true
        debugLog("down", x: x)
        onBegan?(x)
        onChanged?(x)
    }

    override func mouseDragged(with event: NSEvent) {
        guard capturesPointerInput, isTrackingPointer else { return }
        let x = localX(for: event)
        debugLog("drag", x: x)
        onChanged?(x)
    }

    override func mouseUp(with event: NSEvent) {
        guard capturesPointerInput, isTrackingPointer else { return }
        let x = localX(for: event)
        isTrackingPointer = false
        debugLog("up", x: x)
        onEnded?(x)
    }

    private func localX(for event: NSEvent) -> CGFloat {
        let point = convert(event.locationInWindow, from: nil)
        return min(max(point.x, 0), bounds.width)
    }

    private func debugLog(_ event: String, x: CGFloat) {
        guard Self.pointerDiagnosticsEnabled else { return }
        debugLog(event, point: NSPoint(x: x, y: 0), extra: "localX=\(String(format: "%.2f", Double(x)))")
    }

    private func debugResolvedTarget(for event: NSEvent, source: String) {
        guard Self.pointerDiagnosticsEnabled, let window, let contentView = window.contentView else { return }
        let pointInContent = contentView.convert(event.locationInWindow, from: nil)
        let target = contentView.hitTest(pointInContent)
        let pointInSelf = convert(event.locationInWindow, from: nil)
        debugLog(
            "resolved-target",
            point: pointInSelf,
            extra: "source=\(source) contentPoint=\(NSStringFromPoint(pointInContent)) target=\(debugViewDescription(target)) selfIsTarget=\(target === self)"
        )
    }

    private func debugAttachTimeEvidence(phase: String) {
        guard Self.pointerDiagnosticsEnabled, let window, let contentView = window.contentView else { return }
        guard completedDiagnosticProbePhases.insert(phase).inserted else { return }

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let centerInWindow = convert(center, to: nil)
        debugLog(
            "attach-probe-window",
            point: center,
            extra: "phase=\(phase) centerInWindow=\(NSStringFromPoint(centerInWindow)) contentView=\(debugViewDescription(contentView))"
        )

        var depth = 0
        var current: NSView? = self
        while let ancestor = current {
            let pointInAncestor = ancestor.convert(center, from: self)
            let target = debugHitTest(ancestor, point: pointInAncestor)
            debugLog(
                "attach-probe-ancestor",
                point: center,
                extra: "phase=\(phase) depth=\(depth) ancestorPoint=\(NSStringFromPoint(pointInAncestor)) ancestor=\(debugViewDescription(ancestor)) hitTarget=\(debugViewDescription(target)) targetRelation=\(debugTargetRelation(target))"
            )

            if let parent = ancestor.superview {
                let childIndex = parent.subviews.firstIndex { $0 === ancestor }
                let siblingOrder = parent.subviews.enumerated()
                    .map { index, sibling in "\(index):\(debugViewDescription(sibling))" }
                    .joined(separator: " | ")
                debugLog(
                    "attach-probe-siblings",
                    point: center,
                    extra: "phase=\(phase) depth=\(depth) parent=\(debugViewDescription(parent)) childIndex=\(childIndex.map(String.init) ?? "nil") rawSubviews=[\(siblingOrder)]"
                )
            }

            if ancestor === contentView { break }
            current = ancestor.superview
            depth += 1
        }

        let centerInContent = contentView.convert(center, from: self)
        let contentTarget = debugHitTest(contentView, point: centerInContent)
        debugLog(
            "attach-probe-content-target",
            point: center,
            extra: "phase=\(phase) contentPoint=\(NSStringFromPoint(centerInContent)) contentView=\(debugViewDescription(contentView)) hitTarget=\(debugViewDescription(contentTarget)) targetRelation=\(debugTargetRelation(contentTarget))"
        )
    }

    private func debugHitTest(_ view: NSView, point: NSPoint) -> NSView? {
        let threadDictionary = Thread.current.threadDictionary
        let previous = threadDictionary[Self.attachProbeThreadKey]
        threadDictionary[Self.attachProbeThreadKey] = true
        defer {
            if let previous {
                threadDictionary[Self.attachProbeThreadKey] = previous
            } else {
                threadDictionary.removeObject(forKey: Self.attachProbeThreadKey)
            }
        }
        return view.hitTest(point)
    }

    private func debugTargetRelation(_ target: NSView?) -> String {
        guard let target else { return "nil" }
        if target === self { return "candidate" }

        var current: NSView? = target
        while let view = current {
            if view === self { return "candidate-descendant" }
            current = view.superview
        }

        current = self
        while let view = current {
            if view === target { return "candidate-ancestor" }
            current = view.superview
        }
        return "other"
    }

    private func debugLog(_ event: String, point: NSPoint = .zero, extra: @autoclosure () -> String) {
        guard Self.pointerDiagnosticsEnabled else { return }
        let extra = extra()
        let line = String(
            format: "%@ source=%@ event=%@ point=%@ bounds=%@ frame=%@ window=%@ %@\n",
            ISO8601DateFormatter().string(from: Date()),
            debugSource,
            event,
            NSStringFromPoint(point),
            NSStringFromRect(bounds),
            NSStringFromRect(frame),
            debugWindowDescription(window),
            extra
        )
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/tatwo-slider-pointer.log")
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func debugSuperviewChain() -> String {
        var names: [String] = []
        var current: NSView? = self
        while let view = current {
            names.append(debugViewDescription(view))
            current = view.superview
        }
        return names.joined(separator: " <- ")
    }

    private func debugViewDescription(_ view: NSView?) -> String {
        guard let view else { return "nil" }
        return "\(String(describing: type(of: view)))@\(ObjectIdentifier(view)) frame=\(NSStringFromRect(view.frame)) bounds=\(NSStringFromRect(view.bounds)) isHidden=\(view.isHidden) alphaValue=\(String(format: "%.3f", Double(view.alphaValue))) mouseDownCanMoveWindow=\(view.mouseDownCanMoveWindow)"
    }

    private func debugWindowDescription(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }
        return "\(String(describing: type(of: window))) frame=\(NSStringFromRect(window.frame)) isMovableByWindowBackground=\(window.isMovableByWindowBackground) ignoresMouseEvents=\(window.ignoresMouseEvents) acceptsMouseMovedEvents=\(window.acceptsMouseMovedEvents)"
    }
}

final class LiquidGlassDashboardSliderContainerView: LiquidGlassDashboardSliderPointerCaptureView {
    let webView: LiquidGlassDashboardHitTransparentWebView

    init(configuration: WKWebViewConfiguration) {
        self.webView = LiquidGlassDashboardHitTransparentWebView(frame: .zero, configuration: configuration)
        super.init(debugSource: "lgd-material")
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.isOpaque = false
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.layer?.drawsAsynchronously = false
        webView.setAccessibilityElement(false)
        addSubview(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }
}

/// A non-rendering AppKit responder deliberately placed outside the material
/// clip/opacity stack. It receives the native down/drag/up sequence while the
/// WebGL container stays visual-only and pointer-transparent.

/// Renders the Ultrawork strength bar with the actual Liquid Glass Dashboard
/// WebGL shader lineage instead of SwiftUI "fake reflection" overlays.
///
/// Source lineage: Liquid Glass Dashboard 本機安裝位置，見 docs（shader 內嵌於此檔，
/// 不在 runtime 讀外接卷）。Reference renderer sha256
/// `f1b756e479bddec40c0393996023203cc3ede625a9aeab174c8b9a5a5b13060c`.
///
/// The HTML below keeps the Dashboard SDF/refraction/chromatic shader logic and
/// feeds it the current slider rainbow as texture. The WebGL child remains
/// pointer-transparent; a separate AppKit overlay reports local x-position
/// down/drag/up to ChatPage, which remains the SwiftUI state source of truth.
struct LiquidGlassDashboardSliderMaterial: NSViewRepresentable {
    var progress: CGFloat
    var isVisible: Bool

    func makeNSView(context: Context) -> LiquidGlassDashboardSliderContainerView {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        let webpagePreferences = WKWebpagePreferences()
        webpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = webpagePreferences
        let container = LiquidGlassDashboardSliderContainerView(configuration: configuration)
        container.webView.loadHTMLString(Self.html, baseURL: nil)
        return container
    }

    func updateNSView(_ container: LiquidGlassDashboardSliderContainerView, context: Context) {
        let clampedProgress = min(max(Double(progress), 0.0), 1.0)
        let js = "window.tatwoUpdateLiquidSlider && window.tatwoUpdateLiquidSlider({progress:\(clampedProgress), visible:\(isVisible ? "true" : "false")});"
        container.webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private static let html = """
    <!doctype html>
    <html>
    <head>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        html, body, canvas {
          margin: 0;
          width: 100%;
          height: 100%;
          overflow: hidden;
          background: transparent;
          pointer-events: none;
        }
        canvas { display: block; }
      </style>
    </head>
    <body>
      <canvas id="lgd"></canvas>
      <script>
      (() => {
        const dashboard = {
          alpha: 0.18,
          tint: [1.0, 1.0, 1.0],
          saturation: 1.0,
          distortion: 1.25,
          blur: 2.2,
          chromaticAberration: 0.75,
          shadowIntensity: 0.04,
          shadowOffset: [0.0, 4.0],
          shadowBlur: 14.0,
          radiusPx: 34.0
        };
        let state = { progress: 0.12, visible: true };
        const canvas = document.getElementById('lgd');
        const gl = canvas.getContext('webgl', { premultipliedAlpha: false, alpha: true, preserveDrawingBuffer: false });
        if (!gl) return;
        gl.getExtension('OES_standard_derivatives');

        const vertexShaderSource = `
          attribute vec2 a_position;
          attribute vec2 a_texCoord;
          varying vec2 v_texCoord;
          void main() {
            gl_Position = vec4(a_position, 0.0, 1.0);
            v_texCoord = a_texCoord;
          }
        `;

        // Copied from Liquid Glass Dashboard SourceGlassRenderer fragment shader
        // with the same SDF/refraction/highlight/chromatic logic. Only shape
        // geometry is fed by this slider's current progress width.
        const fragmentShaderSource = `
          #ifdef GL_OES_standard_derivatives
          #extension GL_OES_standard_derivatives : enable
          #endif
          precision mediump float;
          uniform float u_time;
          uniform vec2 u_resolution;
          uniform vec2 u_mouse;
          uniform sampler2D u_texture;
          uniform float u_width;
          uniform float u_height;
          uniform vec3 u_tint;
          uniform float u_saturation;
          uniform float u_distortion;
          uniform float u_blur;
          uniform float u_imageAspect;
          uniform float u_canvasAspect;
          uniform float u_shadowIntensity;
          uniform vec2 u_shadowOffset;
          uniform float u_shadowBlur;
          uniform float u_cornerRadius;
          uniform float u_chromaticAberration;
          uniform float u_layerAlpha;
          varying vec2 v_texCoord;
          vec2 getCoverUV(vec2 uv, float imageAspect, float canvasAspect) {
            vec2 coverUV = uv;
            if (imageAspect > canvasAspect) {
              float scale = canvasAspect / imageAspect;
              coverUV.x = (uv.x - 0.5) * scale + 0.5;
            } else {
              float scale = imageAspect / canvasAspect;
              coverUV.y = (uv.y - 0.5) * scale + 0.5;
            }
            return coverUV;
          }
          float sdRoundedRect(vec2 pos, vec2 halfSize, vec4 cornerRadius) {
            cornerRadius.xy = (pos.x > 0.0) ? cornerRadius.xy : cornerRadius.zw;
            cornerRadius.x = (pos.y > 0.0) ? cornerRadius.x : cornerRadius.y;
            vec2 q = abs(pos) - halfSize + cornerRadius.x;
            return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - cornerRadius.x;
          }
          float boxSDF(vec2 uv) { return sdRoundedRect(uv, vec2(u_width, u_height), vec4(u_cornerRadius)); }
          float shadowSDF(vec2 uv) { return boxSDF(uv - u_shadowOffset); }
          vec2 randomVec2(vec2 co) {
            return fract(sin(vec2(dot(co, vec2(127.1, 311.7)), dot(co, vec2(269.5, 183.3)))) * 43758.5453);
          }
          vec3 sampleWithNoise(vec2 uv, float timeOffset, float mipLevel) {
            vec2 coverUV = getCoverUV(uv, u_imageAspect, u_canvasAspect);
            vec2 offset = randomVec2(coverUV + vec2(u_time + timeOffset)) / u_resolution.x;
            return texture2D(u_texture, coverUV + offset * pow(2.0, mipLevel) * 0.01).rgb;
          }
          vec3 sampleWithChromaticAberration(vec2 uv, float timeOffset, float mipLevel, float aberrationStrength) {
            if (aberrationStrength <= 0.0) return sampleWithNoise(uv, timeOffset, mipLevel);
            vec2 coverUV = getCoverUV(uv, u_imageAspect, u_canvasAspect);
            vec2 center = vec2(0.5);
            vec2 direction = normalize(coverUV - center);
            float distance = length(coverUV - center);
            float aberrationOffset = aberrationStrength * distance * 0.01;
            vec2 offset = randomVec2(coverUV + vec2(u_time + timeOffset)) / u_resolution.x;
            vec2 noiseOffset = offset * pow(2.0, mipLevel) * 0.01;
            float r = texture2D(u_texture, coverUV + direction * aberrationOffset * 1.2 + noiseOffset).r;
            float g = texture2D(u_texture, coverUV + noiseOffset).g;
            float b = texture2D(u_texture, coverUV - direction * aberrationOffset * 0.8 + noiseOffset).b;
            return vec3(r, g, b);
          }
          vec3 getBlurredColor(vec2 uv, float mipLevel) {
            return (
              sampleWithChromaticAberration(uv, 0.0, mipLevel, u_chromaticAberration) +
              sampleWithChromaticAberration(uv, 0.25, mipLevel, u_chromaticAberration) +
              sampleWithChromaticAberration(uv, 0.5, mipLevel, u_chromaticAberration) +
              sampleWithChromaticAberration(uv, 0.75, mipLevel, u_chromaticAberration) +
              sampleWithChromaticAberration(uv, 1.0, mipLevel, u_chromaticAberration) +
              sampleWithChromaticAberration(uv, 1.25, mipLevel, u_chromaticAberration) +
              sampleWithChromaticAberration(uv, 1.5, mipLevel, u_chromaticAberration) +
              sampleWithChromaticAberration(uv, 1.75, mipLevel, u_chromaticAberration) +
              sampleWithChromaticAberration(uv, 2.0, mipLevel, u_chromaticAberration)
            ) * 0.11111;
          }
          vec3 saturate(vec3 color, float factor) {
            float gray = dot(color, vec3(0.299, 0.587, 0.114));
            return mix(vec3(gray), color, factor);
          }
          vec2 computeRefractOffset(float sdf, vec2 fragCoord) {
            if (sdf < 0.1) return vec2(0.0);
            #ifdef GL_OES_standard_derivatives
            vec2 grad = normalize(vec2(dFdx(sdf), dFdy(sdf)));
            #else
            vec2 grad = normalize(vec2(0.1, 0.1));
            #endif
            float offsetAmount = pow(abs(sdf), 12.0) * -0.05 * u_distortion;
            return grad * offsetAmount;
          }
          float highlight(float sdf, vec2 fragCoord) { return 0.0; }
          float gaussianBlur(vec2 uv, float blurSize) {
            float total = 0.0;
            float totalWeight = 0.0;
            float radius = min(blurSize, 15.0);
            for (int x = -15; x <= 15; x++) {
              for (int y = -15; y <= 15; y++) {
                if (float(x) >= -radius && float(x) <= radius && float(y) >= -radius && float(y) <= radius) {
                  vec2 samplePos = (uv * u_resolution + vec2(float(x), float(y))) - u_mouse;
                  float weight = exp(-(float(x*x + y*y)) / (2.0 * radius * radius));
                  float shadowValue = 1.0 - clamp(shadowSDF(samplePos), 0.0, 1.0);
                  total += weight * shadowValue;
                  totalWeight += weight;
                }
              }
            }
            return totalWeight > 0.0 ? total / totalWeight : 0.0;
          }
          void main() {
            vec2 fragCoord = v_texCoord * u_resolution;
            vec2 centeredUV = fragCoord - u_mouse;
            float sdf = boxSDF(centeredUV);
            float normalizedInside = (sdf / u_height) + 1.0;
            float edgeBlendFactor = pow(normalizedInside, 12.0);
            vec2 coverUV = getCoverUV(v_texCoord, u_imageAspect, u_canvasAspect);
            vec3 baseTex = texture2D(u_texture, coverUV).rgb;
            float shadowMask = 0.0;
            if (u_shadowIntensity > 0.0) shadowMask = gaussianBlur(v_texCoord, u_shadowBlur) * u_shadowIntensity;
            vec2 sampleUV = v_texCoord + computeRefractOffset(normalizedInside, fragCoord);
            float mipLevel = mix(3.5 * u_blur, 1.5, edgeBlendFactor);
            vec3 blurredTex = getBlurredColor(sampleUV, mipLevel);
            blurredTex = mix(blurredTex, pow(saturate(blurredTex, u_saturation), vec3(0.5)), edgeBlendFactor);
            blurredTex *= u_tint;
            // Keep the Dashboard SDF/refraction/chromatic pipeline, but do not add
            // the white reflection pass here: on a 34px rainbow slider it reads as
            // an artificial convex mirror instead of the warehouse glass material.
            blurredTex += 0.0 * highlight(normalizedInside, fragCoord);
            blurredTex = mix(blurredTex, blurredTex * 1.1, 0.2);
            float boxMask = 1.0 - clamp(sdf, 0.0, 1.0);
            vec3 shadowedBackground = mix(baseTex, baseTex * (1.0 - shadowMask), step(0.01, shadowMask));
            float baseAlpha = clamp(u_layerAlpha, 0.06, 0.55);
            float edgeAlpha = clamp(baseAlpha * 2.4, 0.16, 0.68);
            float stackAlpha = mix(baseAlpha, edgeAlpha, clamp(edgeBlendFactor, 0.0, 1.0));
            float alpha = smoothstep(0.0, 1.0, boxMask) * stackAlpha;
            gl_FragColor = vec4(mix(shadowedBackground, blurredTex, vec3(boxMask)), alpha);
          }
        `;

        function compile(type, source) {
          const shader = gl.createShader(type);
          gl.shaderSource(shader, source);
          gl.compileShader(shader);
          if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader));
          return shader;
        }
        const program = gl.createProgram();
        gl.attachShader(program, compile(gl.VERTEX_SHADER, vertexShaderSource));
        gl.attachShader(program, compile(gl.FRAGMENT_SHADER, fragmentShaderSource));
        gl.linkProgram(program);
        if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
        const data = new Float32Array([-1,-1,0,1, 1,-1,1,1, -1,1,0,0, 1,1,1,0]);
        const buffer = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
        gl.bufferData(gl.ARRAY_BUFFER, data, gl.STATIC_DRAW);
        const aPos = gl.getAttribLocation(program, 'a_position');
        const aTex = gl.getAttribLocation(program, 'a_texCoord');
        gl.enableVertexAttribArray(aPos);
        gl.enableVertexAttribArray(aTex);
        gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 16, 0);
        gl.vertexAttribPointer(aTex, 2, gl.FLOAT, false, 16, 8);
        const uniforms = {};
        ['u_time','u_resolution','u_mouse','u_texture','u_width','u_height','u_tint','u_saturation','u_distortion','u_blur','u_imageAspect','u_canvasAspect','u_shadowIntensity','u_shadowOffset','u_shadowBlur','u_cornerRadius','u_chromaticAberration','u_layerAlpha'].forEach((name) => uniforms[name] = gl.getUniformLocation(program, name));
        const texture = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, texture);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.enable(gl.BLEND);
        gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
        const gradientCanvas = document.createElement('canvas');
        const gradientContext = gradientCanvas.getContext('2d');
        const startedAt = performance.now();

        function updateGradientTexture(width, height) {
          gradientCanvas.width = width;
          gradientCanvas.height = height;
          const gradient = gradientContext.createLinearGradient(0, 0, width, 0);
          gradient.addColorStop(0.00, 'rgba(250, 97, 255, 1)');
          gradient.addColorStop(0.36, 'rgba(184, 107, 255, 1)');
          gradient.addColorStop(0.68, 'rgba(128, 153, 255, 1)');
          gradient.addColorStop(1.00, 'rgba(255, 158, 209, 1)');
          gradientContext.fillStyle = gradient;
          gradientContext.fillRect(0, 0, width, height);
          gl.bindTexture(gl.TEXTURE_2D, texture);
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, gradientCanvas);
        }

        function draw() {
          const ratio = window.devicePixelRatio || 1;
          const rect = canvas.getBoundingClientRect();
          const width = Math.max(2, Math.round(rect.width * ratio));
          const height = Math.max(2, Math.round(rect.height * ratio));
          if (canvas.width !== width || canvas.height !== height) {
            canvas.width = width;
            canvas.height = height;
            gl.viewport(0, 0, width, height);
            updateGradientTexture(width, height);
          }
          gl.clearColor(0, 0, 0, 0);
          gl.clear(gl.COLOR_BUFFER_BIT);
          if (!state.visible) return;
          const progressWidth = Math.max(30 * ratio, Math.min(width + 2 * ratio, width * state.progress));
          // Slight vertical overdraw is intentional: the SwiftUI Capsule clips
          // the WebGL surface, while the LGD SDF must not sit 1-2 px inside the
          // bottom capsule. Otherwise the shader/shadow edge reads as black
          // top/bottom seams on this 34px control.
          const halfHeight = Math.max(2, height * 0.5 + 1.35 * ratio);
          const radius = Math.min(dashboard.radiusPx * ratio, height * 0.5);
          gl.useProgram(program);
          gl.activeTexture(gl.TEXTURE0);
          gl.bindTexture(gl.TEXTURE_2D, texture);
          gl.uniform1i(uniforms.u_texture, 0);
          gl.uniform1f(uniforms.u_time, (performance.now() - startedAt) / 1000);
          gl.uniform2f(uniforms.u_resolution, width, height);
          gl.uniform2f(uniforms.u_mouse, progressWidth * 0.5, height * 0.5);
          gl.uniform1f(uniforms.u_width, progressWidth * 0.5);
          gl.uniform1f(uniforms.u_height, halfHeight);
          gl.uniform3f(uniforms.u_tint, dashboard.tint[0], dashboard.tint[1], dashboard.tint[2]);
          gl.uniform1f(uniforms.u_saturation, dashboard.saturation);
          gl.uniform1f(uniforms.u_distortion, dashboard.distortion);
          gl.uniform1f(uniforms.u_blur, dashboard.blur);
          gl.uniform1f(uniforms.u_imageAspect, width / height);
          gl.uniform1f(uniforms.u_canvasAspect, width / height);
          gl.uniform1f(uniforms.u_shadowIntensity, dashboard.shadowIntensity);
          gl.uniform2f(uniforms.u_shadowOffset, dashboard.shadowOffset[0] * ratio, dashboard.shadowOffset[1] * ratio);
          gl.uniform1f(uniforms.u_shadowBlur, dashboard.shadowBlur * ratio);
          gl.uniform1f(uniforms.u_cornerRadius, radius);
          gl.uniform1f(uniforms.u_chromaticAberration, dashboard.chromaticAberration);
          gl.uniform1f(uniforms.u_layerAlpha, dashboard.alpha);
          gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
        }

        let frame = null;
        function scheduleDraw() {
          if (frame) cancelAnimationFrame(frame);
          frame = requestAnimationFrame(() => { frame = null; draw(); });
        }
        window.tatwoUpdateLiquidSlider = (next) => {
          state.progress = Math.max(0, Math.min(1, Number(next.progress || 0)));
          state.visible = !!next.visible;
          scheduleDraw();
        };
        new ResizeObserver(scheduleDraw).observe(canvas);
        scheduleDraw();
      })();
      </script>
    </body>
    </html>
    """
}
#endif
