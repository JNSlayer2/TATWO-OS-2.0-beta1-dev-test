import AppKit

@MainActor func renderAttachmentPreviewSurfaces() throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let destination = URL(fileURLWithPath: CommandLine.arguments[1])
    let picture = NSImage(size: NSSize(width: 570, height: 420))
    picture.lockFocus()
    NSColor(calibratedRed: 0.20, green: 0.57, blue: 0.79, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 570, height: 420).fill()
    NSColor(calibratedRed: 0.24, green: 0.68, blue: 0.45, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: -100, y: -170, width: 710, height: 440)).fill()
    NSColor(calibratedRed: 0.98, green: 0.84, blue: 0.30, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 380, y: 270, width: 72, height: 72)).fill()
    picture.unlockFocus()

    var failures = 0
    func check(_ name: String, _ value: Bool) {
        print("ATTACHMENTPREVIEWSURFACE \(value ? "PASS" : "FAIL") \(name)")
        if !value { failures += 1 }
    }
    func render(_ content: some View, _ name: String, width: CGFloat, height: CGFloat) throws -> NSBitmapImageRep {
        let view = NSHostingView(rootView: content.frame(width: width, height: height))
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view // Never show/capture any live application.
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name + ".png"))
        window.close()
        print("ATTACHMENTPREVIEWSURFACE RENDER \(name) points=\(Int(width))x\(Int(height)) pixels=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
        return bitmap
    }
    let thumbnail = try render(
        HStack(alignment: .top, spacing: 12) {
            ChatImageAttachmentThumbnail(image: Image(nsImage: picture), name: "示範圖片", open: {}, remove: {})
            ChatImageAttachmentThumbnail(image: nil, name: "遺失圖片", open: {}, remove: {})
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.94, green: 0.93, blue: 0.88)),
        "thumbnail", width: 280, height: 130)
    func color(_ bitmap: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat, width: CGFloat, height: CGFloat) -> NSColor {
        bitmap.colorAt(x: Int(x / width * CGFloat(bitmap.pixelsWide)),
                       y: Int(y / height * CGFloat(bitmap.pixelsHigh)))!.usingColorSpace(.deviceRGB)!
    }
    let inside = color(thumbnail, 60, 60, width: 280, height: 130)
    check("thumbnail contains actual image pixels", inside.greenComponent > 0.3 && inside.redComponent < 0.5)
    let gap = color(thumbnail, 106, 60, width: 280, height: 130)
    check("thumbnail does not overflow adjacent slot", gap.redComponent > 0.8 && gap.greenComponent > 0.8)
    for width in [CGFloat(720), 1200] {
        let height: CGFloat = width == 720 ? 600 : 780
        let bitmap = try render(
            ZStack {
                Color(red: 0.94, green: 0.93, blue: 0.88)
                ChatImagePreviewSurface(image: Image(nsImage: picture), imageSize: picture.size,
                    name: "示範圖片", canGoForward: true, close: {}, save: {},
                    zoomOut: {}, zoomIn: {}, previous: {}, next: {})
            },
            "expanded-\(Int(width))", width: width, height: height)
        let center = color(bitmap, width / 2, height / 2, width: width, height: height)
        let backdrop = color(bitmap, 70, 70, width: width, height: height)
        check("expanded image is visible at \(Int(width))pt", center.greenComponent > 0.3 && center.redComponent < 0.5)
        check("backdrop is dimmed at \(Int(width))pt", backdrop.redComponent < 0.3 && backdrop.greenComponent < 0.3)
    }
    let singleWidth: CGFloat = 1200, singleHeight: CGFloat = 780
    let single = try render(
        ZStack {
            Color(red: 0.94, green: 0.93, blue: 0.88)
            ChatImagePreviewSurface(image: Image(nsImage: picture),
                imageSize: CGSize(width: 234, height: 171), name: "單張示範",
                close: {}, save: {}, zoomOut: {}, zoomIn: {}, previous: {}, next: {})
        }, "expanded-single", width: singleWidth, height: singleHeight)
    let singleCenter = color(single, 600, 390, width: singleWidth, height: singleHeight)
    let outsideSingle = color(single, 730, 390, width: singleWidth, height: singleHeight)
    check("single small image remains centered", singleCenter.greenComponent > 0.3 && singleCenter.redComponent < 0.5)
    check("single small image is not enlarged to fill overlay", outsideSingle.redComponent < 0.3 && outsideSingle.greenComponent < 0.3)
    _ = try render(
        ChatImagePreviewSurface(image: nil, imageSize: .zero, name: "遺失圖片",
            error: "圖片已移動或無法讀取", close: {}, save: {},
            zoomOut: {}, zoomIn: {}, previous: {}, next: {}),
        "unavailable", width: 720, height: 600)
    print("ATTACHMENTPREVIEWSURFACE RESULT failed=\(failures)")
    exit(failures == 0 ? 0 : 1)
}

try MainActor.assumeIsolated { try renderAttachmentPreviewSurfaces() }
