import SwiftUI
import AppKit

/// Live I/O wrapper around the approved presentation-only thumbnail.
struct ChatLoadedImageAttachment: View {
    let attachment: ChatInlineAttachment
    var gallery: [ChatInlineAttachment] = []
    var size: CGFloat = 80
    var remove: (() -> Void)?
    @State private var image: CGImage?
    @State private var isLoading = true
    @State private var isPreviewPresented = false

    var body: some View {
        ChatImageAttachmentThumbnail(
            image: image.map { Image(decorative: $0, scale: 1) },
            name: attachment.displayName,
            isLoading: isLoading,
            size: size,
            open: { isPreviewPresented = true },
            remove: remove)
        .task(id: attachment.path) {
            image = nil
            isLoading = true
            let loaded = await ChatAttachmentImageLoader.shared.load(
                url: attachment.url,
                maxPixelSize: ChatAttachmentImageLoader.thumbnailPixelLimit)
            guard !Task.isCancelled else { return }
            image = loaded
            isLoading = false
        }
        .sheet(isPresented: $isPreviewPresented) {
            ChatAttachmentImagePreview(
                attachments: gallery.isEmpty ? [attachment] : gallery,
                initialPath: attachment.path)
        }
    }
}

/// Selection and actions are local to this presentation, never global app state.
struct ChatAttachmentImagePreview: View {
    let attachments: [ChatInlineAttachment]
    let initialPath: String
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPath: String?
    @State private var image: CGImage?
    @State private var isLoading = true
    @State private var zoom: CGFloat = 1
    @State private var saveError: String?
    @State private var isSaving = false

    private var selectedIndex: Int {
        attachments.firstIndex { $0.path == (selectedPath ?? initialPath) } ?? 0
    }

    private var selection: ChatInlineAttachment? {
        attachments.indices.contains(selectedIndex) ? attachments[selectedIndex] : nil
    }

    var body: some View {
        ChatImagePreviewSurface(
            image: image.map { Image(decorative: $0, scale: 1) },
            imageSize: image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero,
            name: selection?.displayName ?? "圖片",
            zoom: zoom,
            isLoading: isLoading,
            error: "圖片已移動或無法讀取",
            canGoBack: selectedIndex > 0,
            canGoForward: selectedIndex + 1 < attachments.count,
            canSave: !isSaving,
            close: { dismiss() },
            save: save,
            zoomOut: { zoom = max(0.25, zoom / 1.25) },
            zoomIn: { zoom = min(4, zoom * 1.25) },
            previous: { moveSelection(by: -1) },
            next: { moveSelection(by: 1) })
        .frame(minWidth: 560, idealWidth: 900, minHeight: 440, idealHeight: 650)
        .task(id: selection?.path) {
            image = nil
            zoom = 1
            isLoading = true
            guard let selection else {
                isLoading = false
                return
            }
            let loaded = await ChatAttachmentImageLoader.shared.load(
                url: selection.url,
                maxPixelSize: ChatAttachmentImageLoader.previewPixelLimit)
            guard !Task.isCancelled else { return }
            image = loaded
            isLoading = false
        }
        .alert("無法儲存圖片", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } })) {
                Button("好", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
    }

    private func moveSelection(by offset: Int) {
        let index = selectedIndex + offset
        guard attachments.indices.contains(index) else { return }
        selectedPath = attachments[index].path
    }

    private func save() {
        guard let selection, !isSaving else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = selection.url.lastPathComponent
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            let source = selection.url
            guard source.standardizedFileURL != destination.standardizedFileURL else { return }
            isSaving = true
            Task {
                let error = await Task.detached(priority: .utility) { () -> String? in
                    do {
                        // Atomic replacement only after the user's Save-panel confirmation.
                        let bytes = try Data(contentsOf: source, options: .mappedIfSafe)
                        try bytes.write(to: destination, options: .atomic)
                        return nil
                    } catch {
                        return "儲存失敗，請確認目的地可寫入後重試。"
                    }
                }.value
                isSaving = false
                saveError = error
            }
        }
    }
}
