#if os(macOS)
import SwiftUI
import WebKit

/// Explicit sRGB values for the WebGL material. `tatwoVioletPink` is the
/// midpoint of LiquidGlassTokens.accentViolet and accentPink, so the shader
/// receives the approved purple-color tint without trying to introspect a
/// dynamic SwiftUI Color.
struct LiquidGlassPanelRGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    static let tatwoVioletPink = LiquidGlassPanelRGB(
        red: (0.757 + 0.937) / 2,
        green: (0.682 + 0.773) / 2,
        blue: (0.949 + 0.878) / 2
    )

    /// Dashboard 玻璃1 真值 tint #ffffff：不加色，讓環境色靠折射自己進來。
    static let neutralWhite = LiquidGlassPanelRGB(red: 1, green: 1, blue: 1)
}

final class LiquidGlassPanelContainerView: NSView {
    let webView: LiquidGlassDashboardHitTransparentWebView

    init(configuration: WKWebViewConfiguration) {
        webView = LiquidGlassDashboardHitTransparentWebView(
            frame: .zero,
            configuration: configuration
        )
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.isOpaque = false
        webView.layer?.backgroundColor = NSColor.clear.cgColor
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// Reusable, pointer-transparent Liquid Glass Dashboard WebGL panel.
///
/// Dashboard source values:
/// alpha 0.18, saturation 1.0, distortion 1.25, blur 2.2,
/// chromatic aberration 0.75, shadow 0/4/14, radius supplied by the caller.
/// The source texture uses the exact approved accentPink/accentViolet RGB pair.
/// Optical parameters for the WebGL glass. Defaults = the approved panel
/// values; the island passes the user's Dashboard-tuned set (2026-08-16).
struct LiquidGlassPanelOptics: Equatable {
    var alpha: Double
    var saturation: Double
    var distortion: Double
    var blur: Double
    var chromaticAberration: Double
    /// 折射來源紋理的彩度。1 = 原本的粉／紫程序紋理（面板身份色）；
    /// 0 = 中性灰，讓玻璃只吃背後 behind-window 取景的環境色，不泛粉。
    var sourceSaturation: Double = 1.0
    /// 邊緣 alpha 增益。面板用 2.4 會把邊緣推成白色鑲條；玻璃鑲邊要靠
    /// 色散而不是靠不透明度。
    var edgeAlphaGain: Double = 2.4
    /// 邊緣 gamma。0.5 提亮很強（塑膠白邊），接近 1 保留原始明暗。
    var edgeGamma: Double = 0.5
    /// 內部 alpha 係數。折射來源是程序紋理而非真實桌面取景，整片鋪滿就成了
    /// 粉白霧板；島身把內部壓掉、只留邊緣折射／色散帶，中央交還給
    /// behind-window 取景玻璃。1 = 面板原行為。
    var interiorAlphaScale: Double = 1.0

    static let panelDefault = LiquidGlassPanelOptics(
        alpha: 0.18, saturation: 1.0, distortion: 1.25,
        blur: 2.2, chromaticAberration: 0.75
    )
    /// 使用者 2026-08-16 Dashboard 玻璃1 實調真值（500x172 R28 layer）。
    /// 光學真值不動；來源彩度與邊緣增益改為中性，粉白霧來自這兩者而非真值。
    /// Island 已改用系統原生 glassEffect，不再消費這組參數；保留給
    /// Aurora 主題重做（goal 指定沿用 island 研究出的液態玻璃真值）。
    static let islandTuned = LiquidGlassPanelOptics(
        alpha: 0.18, saturation: 1.0, distortion: 1.3,
        blur: 2.2, chromaticAberration: 1.5,
        sourceSaturation: 0.0, edgeAlphaGain: 1.25, edgeGamma: 0.85,
        interiorAlphaScale: 0.12
    )
}

struct LiquidGlassPanelWebView: NSViewRepresentable {
    let cornerRadius: CGFloat
    let tintRGB: LiquidGlassPanelRGB
    var optics: LiquidGlassPanelOptics = .panelDefault

    func makeNSView(context: Context) -> LiquidGlassPanelContainerView {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        let webpagePreferences = WKWebpagePreferences()
        webpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = webpagePreferences

        let container = LiquidGlassPanelContainerView(configuration: configuration)
        container.webView.loadHTMLString(
            Self.html(cornerRadius: cornerRadius, tintRGB: tintRGB, optics: optics),
            baseURL: nil
        )
        return container
    }

    func updateNSView(_ container: LiquidGlassPanelContainerView, context: Context) {
        let payload = """
        {
          cornerRadius: \(Double(cornerRadius)),
          tintRGB: [\(tintRGB.red), \(tintRGB.green), \(tintRGB.blue)],
          optics: {
            alpha: \(optics.alpha),
            saturation: \(optics.saturation),
            distortion: \(optics.distortion),
            blur: \(optics.blur),
            chromaticAberration: \(optics.chromaticAberration),
            sourceSaturation: \(optics.sourceSaturation),
            edgeAlphaGain: \(optics.edgeAlphaGain),
            edgeGamma: \(optics.edgeGamma),
            interiorAlphaScale: \(optics.interiorAlphaScale)
          }
        }
        """
        container.webView.evaluateJavaScript(
            "window.tatwoUpdateLiquidPanel && window.tatwoUpdateLiquidPanel(\(payload));",
            completionHandler: nil
        )
    }

    static func dismantleNSView(
        _ container: LiquidGlassPanelContainerView,
        coordinator: Void
    ) {
        container.webView.stopLoading()
    }

    private static func html(
        cornerRadius: CGFloat,
        tintRGB: LiquidGlassPanelRGB,
        optics: LiquidGlassPanelOptics = .panelDefault
    ) -> String {
        """
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
          <canvas id="lgd-panel"></canvas>
          <script>
          (() => {
            const dashboard = {
              alpha: \(optics.alpha),
              saturation: \(optics.saturation),
              distortion: \(optics.distortion),
              blur: \(optics.blur),
              chromaticAberration: \(optics.chromaticAberration),
              sourceSaturation: \(optics.sourceSaturation),
              edgeAlphaGain: \(optics.edgeAlphaGain),
              edgeGamma: \(optics.edgeGamma),
              interiorAlphaScale: \(optics.interiorAlphaScale),
              shadowIntensity: 0.04,
              shadowOffset: [0.0, 4.0],
              shadowBlur: 14.0
            };
            const accentPink = [0.937, 0.773, 0.878];
            const accentViolet = [0.757, 0.682, 0.949];
            let state = {
              radiusPx: \(Double(cornerRadius)),
              tintRGB: [\(tintRGB.red), \(tintRGB.green), \(tintRGB.blue)]
            };
            const canvas = document.getElementById('lgd-panel');
            const gl = canvas.getContext('webgl', {
              premultipliedAlpha: false,
              alpha: true,
              preserveDrawingBuffer: false
            });
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

            // Liquid Glass Dashboard SourceGlassRenderer lineage: rounded-rect
            // SDF, refraction, blur, saturation, chromatic separation and shadow.
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
              uniform float u_edgeAlphaGain;
              uniform float u_edgeGamma;
              uniform float u_interiorAlphaScale;
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
                return min(max(q.x, q.y), 0.0)
                  + length(max(q, 0.0))
                  - cornerRadius.x;
              }

              float boxSDF(vec2 uv) {
                return sdRoundedRect(
                  uv,
                  vec2(u_width, u_height),
                  vec4(u_cornerRadius)
                );
              }

              float shadowSDF(vec2 uv) {
                return boxSDF(uv - u_shadowOffset);
              }

              vec2 randomVec2(vec2 co) {
                return fract(
                  sin(vec2(
                    dot(co, vec2(127.1, 311.7)),
                    dot(co, vec2(269.5, 183.3))
                  )) * 43758.5453
                );
              }

              vec3 sampleWithNoise(vec2 uv, float timeOffset, float mipLevel) {
                vec2 coverUV = getCoverUV(uv, u_imageAspect, u_canvasAspect);
                vec2 offset =
                  randomVec2(coverUV + vec2(u_time + timeOffset))
                  / u_resolution.x;
                return texture2D(
                  u_texture,
                  coverUV + offset * pow(2.0, mipLevel) * 0.01
                ).rgb;
              }

              vec3 sampleWithChromaticAberration(
                vec2 uv,
                float timeOffset,
                float mipLevel,
                float aberrationStrength
              ) {
                if (aberrationStrength <= 0.0) {
                  return sampleWithNoise(uv, timeOffset, mipLevel);
                }
                vec2 coverUV = getCoverUV(uv, u_imageAspect, u_canvasAspect);
                vec2 center = vec2(0.5);
                vec2 direction = normalize(coverUV - center);
                float distance = length(coverUV - center);
                float aberrationOffset =
                  aberrationStrength * distance * 0.01;
                vec2 offset =
                  randomVec2(coverUV + vec2(u_time + timeOffset))
                  / u_resolution.x;
                vec2 noiseOffset =
                  offset * pow(2.0, mipLevel) * 0.01;
                float r = texture2D(
                  u_texture,
                  coverUV + direction * aberrationOffset * 1.2 + noiseOffset
                ).r;
                float g = texture2D(
                  u_texture,
                  coverUV + noiseOffset
                ).g;
                float b = texture2D(
                  u_texture,
                  coverUV - direction * aberrationOffset * 0.8 + noiseOffset
                ).b;
                return vec3(r, g, b);
              }

              vec3 getBlurredColor(vec2 uv, float mipLevel) {
                return (
                  sampleWithChromaticAberration(uv, 0.0, mipLevel, u_chromaticAberration)
                  + sampleWithChromaticAberration(uv, 0.25, mipLevel, u_chromaticAberration)
                  + sampleWithChromaticAberration(uv, 0.5, mipLevel, u_chromaticAberration)
                  + sampleWithChromaticAberration(uv, 0.75, mipLevel, u_chromaticAberration)
                  + sampleWithChromaticAberration(uv, 1.0, mipLevel, u_chromaticAberration)
                  + sampleWithChromaticAberration(uv, 1.25, mipLevel, u_chromaticAberration)
                  + sampleWithChromaticAberration(uv, 1.5, mipLevel, u_chromaticAberration)
                  + sampleWithChromaticAberration(uv, 1.75, mipLevel, u_chromaticAberration)
                  + sampleWithChromaticAberration(uv, 2.0, mipLevel, u_chromaticAberration)
                ) * 0.11111;
              }

              vec3 saturate(vec3 color, float factor) {
                float gray = dot(color, vec3(0.299, 0.587, 0.114));
                return mix(vec3(gray), color, factor);
              }

              vec2 computeRefractOffset(float sdf) {
                if (sdf < 0.1) return vec2(0.0);
                #ifdef GL_OES_standard_derivatives
                vec2 grad = normalize(vec2(dFdx(sdf), dFdy(sdf)));
                #else
                vec2 grad = normalize(vec2(0.1, 0.1));
                #endif
                float offsetAmount =
                  pow(abs(sdf), 12.0) * -0.05 * u_distortion;
                return grad * offsetAmount;
              }

              float gaussianBlur(vec2 uv, float blurSize) {
                float total = 0.0;
                float totalWeight = 0.0;
                float radius = min(blurSize, 15.0);
                for (int x = -15; x <= 15; x++) {
                  for (int y = -15; y <= 15; y++) {
                    if (
                      float(x) >= -radius && float(x) <= radius
                      && float(y) >= -radius && float(y) <= radius
                    ) {
                      vec2 samplePos =
                        (uv * u_resolution + vec2(float(x), float(y)))
                        - u_mouse;
                      float weight =
                        exp(-(float(x*x + y*y)) / (2.0 * radius * radius));
                      float shadowValue =
                        1.0 - clamp(shadowSDF(samplePos), 0.0, 1.0);
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
                vec2 coverUV =
                  getCoverUV(v_texCoord, u_imageAspect, u_canvasAspect);
                vec3 baseTex = texture2D(u_texture, coverUV).rgb;
                float shadowMask = 0.0;
                if (u_shadowIntensity > 0.0) {
                  shadowMask =
                    gaussianBlur(v_texCoord, u_shadowBlur)
                    * u_shadowIntensity;
                }
                vec2 sampleUV =
                  v_texCoord + computeRefractOffset(normalizedInside);
                float mipLevel =
                  mix(3.5 * u_blur, 1.5, edgeBlendFactor);
                vec3 blurredTex = getBlurredColor(sampleUV, mipLevel);
                blurredTex = mix(
                  blurredTex,
                  pow(saturate(blurredTex, u_saturation), vec3(u_edgeGamma)),
                  edgeBlendFactor
                );
                blurredTex *= u_tint;
                blurredTex = mix(blurredTex, blurredTex * 1.1, 0.2);
                float boxMask = 1.0 - clamp(sdf, 0.0, 1.0);
                vec3 shadowedBackground = mix(
                  baseTex,
                  baseTex * (1.0 - shadowMask),
                  step(0.01, shadowMask)
                );
                float baseAlpha = clamp(u_layerAlpha, 0.06, 0.55);
                float edgeAlpha =
                  clamp(baseAlpha * u_edgeAlphaGain, 0.10, 0.68);
                // 內部與邊緣分開：中央壓到 interiorAlphaScale 讓背後取景透
                // 出來，邊緣保留折射／色散帶，玻璃才不是一整片粉白霧板。
                float interiorAlpha =
                  baseAlpha * clamp(u_interiorAlphaScale, 0.0, 1.0);
                float stackAlpha = mix(
                  interiorAlpha,
                  edgeAlpha,
                  clamp(edgeBlendFactor, 0.0, 1.0)
                );
                float alpha =
                  smoothstep(0.0, 1.0, boxMask) * stackAlpha;
                gl_FragColor = vec4(
                  mix(shadowedBackground, blurredTex, vec3(boxMask)),
                  alpha
                );
              }
            `;

            function compile(type, source) {
              const shader = gl.createShader(type);
              gl.shaderSource(shader, source);
              gl.compileShader(shader);
              if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
                throw new Error(gl.getShaderInfoLog(shader));
              }
              return shader;
            }

            const program = gl.createProgram();
            gl.attachShader(
              program,
              compile(gl.VERTEX_SHADER, vertexShaderSource)
            );
            gl.attachShader(
              program,
              compile(gl.FRAGMENT_SHADER, fragmentShaderSource)
            );
            gl.linkProgram(program);
            if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
              throw new Error(gl.getProgramInfoLog(program));
            }

            const data = new Float32Array([
              -1, -1, 0, 1,
               1, -1, 1, 1,
              -1,  1, 0, 0,
               1,  1, 1, 0
            ]);
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
            [
              'u_time', 'u_resolution', 'u_mouse', 'u_texture',
              'u_width', 'u_height', 'u_tint', 'u_saturation',
              'u_distortion', 'u_blur', 'u_imageAspect',
              'u_canvasAspect', 'u_shadowIntensity', 'u_shadowOffset',
              'u_shadowBlur', 'u_cornerRadius',
              'u_chromaticAberration', 'u_layerAlpha',
              'u_edgeAlphaGain', 'u_edgeGamma',
              'u_interiorAlphaScale'
            ].forEach((name) => {
              uniforms[name] = gl.getUniformLocation(program, name);
            });

            const texture = gl.createTexture();
            gl.bindTexture(gl.TEXTURE_2D, texture);
            gl.texParameteri(
              gl.TEXTURE_2D,
              gl.TEXTURE_WRAP_S,
              gl.CLAMP_TO_EDGE
            );
            gl.texParameteri(
              gl.TEXTURE_2D,
              gl.TEXTURE_WRAP_T,
              gl.CLAMP_TO_EDGE
            );
            gl.texParameteri(
              gl.TEXTURE_2D,
              gl.TEXTURE_MIN_FILTER,
              gl.LINEAR
            );
            gl.texParameteri(
              gl.TEXTURE_2D,
              gl.TEXTURE_MAG_FILTER,
              gl.LINEAR
            );
            gl.enable(gl.BLEND);
            gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

            const sourceCanvas = document.createElement('canvas');
            const sourceContext = sourceCanvas.getContext('2d');
            const startedAt = performance.now();

            // sourceSaturation 0 時把身份粉／紫抽成等亮度中性灰：折射進來的
            // 是環境明暗，不是面板色，島身才不會整片偏粉。
            function rgb(color, alpha) {
              const gray =
                color[0] * 0.299 + color[1] * 0.587 + color[2] * 0.114;
              const amount = Math.max(
                0,
                Math.min(1, Number(dashboard.sourceSaturation))
              );
              const mixed = color.map((c) => gray + (c - gray) * amount);
              return `rgba(${mixed[0] * 255}, ${mixed[1] * 255}, ${mixed[2] * 255}, ${alpha})`;
            }

            function updateSourceTexture(width, height) {
              sourceCanvas.width = width;
              sourceCanvas.height = height;
              const gradient = sourceContext.createLinearGradient(
                0,
                0,
                width,
                height
              );
              gradient.addColorStop(0.00, rgb(accentPink, 1));
              gradient.addColorStop(0.48, rgb(accentViolet, 1));
              gradient.addColorStop(1.00, rgb(accentPink, 1));
              sourceContext.fillStyle = gradient;
              sourceContext.fillRect(0, 0, width, height);
              gl.bindTexture(gl.TEXTURE_2D, texture);
              gl.texImage2D(
                gl.TEXTURE_2D,
                0,
                gl.RGBA,
                gl.RGBA,
                gl.UNSIGNED_BYTE,
                sourceCanvas
              );
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
                updateSourceTexture(width, height);
              }

              gl.clearColor(0, 0, 0, 0);
              gl.clear(gl.COLOR_BUFFER_BIT);
              const inset = Math.max(1, ratio);
              const halfWidth = Math.max(2, width * 0.5 - inset);
              const halfHeight = Math.max(2, height * 0.5 - inset);
              const radius = Math.min(
                state.radiusPx * ratio,
                halfWidth,
                halfHeight
              );

              gl.useProgram(program);
              gl.activeTexture(gl.TEXTURE0);
              gl.bindTexture(gl.TEXTURE_2D, texture);
              gl.uniform1i(uniforms.u_texture, 0);
              gl.uniform1f(
                uniforms.u_time,
                (performance.now() - startedAt) / 1000
              );
              gl.uniform2f(uniforms.u_resolution, width, height);
              gl.uniform2f(uniforms.u_mouse, width * 0.5, height * 0.5);
              gl.uniform1f(uniforms.u_width, halfWidth);
              gl.uniform1f(uniforms.u_height, halfHeight);
              gl.uniform3f(
                uniforms.u_tint,
                state.tintRGB[0],
                state.tintRGB[1],
                state.tintRGB[2]
              );
              gl.uniform1f(
                uniforms.u_saturation,
                dashboard.saturation
              );
              gl.uniform1f(
                uniforms.u_distortion,
                dashboard.distortion
              );
              gl.uniform1f(uniforms.u_blur, dashboard.blur);
              gl.uniform1f(uniforms.u_imageAspect, width / height);
              gl.uniform1f(uniforms.u_canvasAspect, width / height);
              gl.uniform1f(
                uniforms.u_shadowIntensity,
                dashboard.shadowIntensity
              );
              gl.uniform2f(
                uniforms.u_shadowOffset,
                dashboard.shadowOffset[0] * ratio,
                dashboard.shadowOffset[1] * ratio
              );
              gl.uniform1f(
                uniforms.u_shadowBlur,
                dashboard.shadowBlur * ratio
              );
              gl.uniform1f(uniforms.u_cornerRadius, radius);
              gl.uniform1f(
                uniforms.u_chromaticAberration,
                dashboard.chromaticAberration
              );
              gl.uniform1f(uniforms.u_layerAlpha, dashboard.alpha);
              gl.uniform1f(
                uniforms.u_edgeAlphaGain,
                dashboard.edgeAlphaGain
              );
              gl.uniform1f(uniforms.u_edgeGamma, dashboard.edgeGamma);
              gl.uniform1f(
                uniforms.u_interiorAlphaScale,
                dashboard.interiorAlphaScale
              );
              gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
            }

            let frame = null;
            function scheduleDraw() {
              if (frame) cancelAnimationFrame(frame);
              frame = requestAnimationFrame(() => {
                frame = null;
                draw();
              });
            }

            window.tatwoUpdateLiquidPanel = (next) => {
              state.radiusPx = Math.max(
                0,
                Number(next.cornerRadius || state.radiusPx)
              );
              if (
                Array.isArray(next.tintRGB)
                && next.tintRGB.length === 3
              ) {
                state.tintRGB = next.tintRGB.map((value) => {
                  return Math.max(0, Math.min(1, Number(value)));
                });
              }
              if (next.optics) {
                const previousSourceSaturation = dashboard.sourceSaturation;
                [
                  'alpha', 'saturation', 'distortion',
                  'blur', 'chromaticAberration',
                  'sourceSaturation', 'edgeAlphaGain', 'edgeGamma',
                  'interiorAlphaScale'
                ].forEach((key) => {
                  const value = Number(next.optics[key]);
                  if (isFinite(value)) dashboard[key] = value;
                });
                if (
                  dashboard.sourceSaturation !== previousSourceSaturation
                  && canvas.width > 0
                  && canvas.height > 0
                ) {
                  updateSourceTexture(canvas.width, canvas.height);
                }
              }
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
}

/// The conditional branch is intentional: hidden surfaces do not create a
/// WKWebView or consume a WebGL context.
struct LiquidGlassPanelMaterial: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    var cornerRadius: CGFloat = LiquidGlassTokens.radiusPrimary
    var tintRGB: LiquidGlassPanelRGB = .tatwoVioletPink
    var optics: LiquidGlassPanelOptics = .panelDefault
    var isVisible = true

    @ViewBuilder
    var body: some View {
        if isVisible {
            LiquidGlassPanelWebView(
                cornerRadius: cornerRadius,
                tintRGB: tintRGB,
                optics: optics
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct LiquidGlassPanelSurfaceModifier: ViewModifier {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let cornerRadius: CGFloat
    let tintRGB: LiquidGlassPanelRGB
    let isVisible: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle)
    }

    // 極光重做（2026-08-20，island 成果落地）：island 的結論原文——
    // 「手工仿製鏈永遠追不上，每多一層就多一塊假底板」。macOS 26+ 面板
    // 改為單一系統 glassEffect（折射/邊光/陰影/明暗自適應全由系統負責，
    // 真實取樣面板後方的 app 內容）＋極光身份漸變（使用者裁決：玻璃管
    // 質感、淡漸變管身份）。同時每視窗省下至多 3 個 WebGL context
    // （低耗能）。舊系統維持原五層 WebGL 鏈。
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background {
                    ZStack {
                        Color.clear
                            .glassEffect(.regular, in: shape)
                        shape.fill(LiquidGlassTokens.ultraworkGradient)
                            .opacity(LiquidGlassTokens.glassIdentityFillOpacity)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            legacyBody(content)
        }
    }

    private func legacyBody(_ content: Content) -> some View {
        content
            .background {
                ZStack {
                    // 1. frost 基底（SwiftUI，headless 可見的模糊底 + 折射近似）
                    shape.fill(.ultraThinMaterial)
                    // 2. 粉藍漸變身份填充（#31 的紫粉辨識度，取代舊小塊淡霧）
                    shape.fill(LiquidGlassTokens.ultraworkGradient)
                        .opacity(LiquidGlassTokens.glassIdentityFillOpacity)
                    // 3. 真 WebGL 折射（限 3 焦點：聊天輸入筐/右資訊卡/左工作區；隱藏不建 context）
                    LiquidGlassPanelMaterial(
                        cornerRadius: cornerRadius,
                        tintRGB: tintRGB,
                        isVisible: isVisible
                    )
                    .clipShape(shape)
                    // 4. 頂緣內高光（玻璃切面反光）
                    shape.fill(LiquidGlassTokens.glassTopHighlight)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                // 5. 清透玻璃 rim（左上白 → 紫 → 藍），一圈玻璃切邊
                shape.strokeBorder(LiquidGlassTokens.glassRimGradient, lineWidth: 1.4)
                    .allowsHitTesting(false)
            }
            .shadow(
                color: .black.opacity(LiquidGlassTokens.shadowOpacity + 0.06),
                radius: LiquidGlassTokens.shadowRadius,
                x: LiquidGlassTokens.shadowOffsetX,
                y: LiquidGlassTokens.shadowOffsetY
            )
    }
}

extension View {
    @ViewBuilder
    func liquidGlassPanelSurface(
        cornerRadius: CGFloat = LiquidGlassTokens.radiusPrimary,
        tintRGB: LiquidGlassPanelRGB = .tatwoVioletPink,
        isVisible: Bool = true
    ) -> some View {
        if TatwoActivePalette.current.usesGlass {
            modifier(
                LiquidGlassPanelSurfaceModifier(
                    cornerRadius: cornerRadius,
                    tintRGB: tintRGB,
                    isVisible: isVisible
                )
            )
        } else {
            // fable5 深度改造：焦點面板不掛 WebGL 玻璃，改扁平牛皮紙 matte（同時省 WebGL context）。
            tatwoMatteSurface(cornerRadius: cornerRadius)
        }
    }
}

struct LiquidGlassPanelCard<Content: View>: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let cornerRadius: CGFloat
    let isVisible: Bool
    private let content: Content

    init(
        cornerRadius: CGFloat = LiquidGlassTokens.radiusPrimary,
        isVisible: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.isVisible = isVisible
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .liquidGlassPanelSurface(
                cornerRadius: cornerRadius,
                isVisible: isVisible
            )
    }
}
#endif
