import SwiftUI

/// Presentation only. The caller owns attachments, loading, saving and selection.
/// Shared by composer and transcript; no file access, global window or model calls.
struct ChatImageAttachmentThumbnail: View {
    let image: Image?
    let name: String
    var isLoading = false
    var size: CGFloat = 80
    let open: () -> Void
    var remove: (() -> Void)?

    var body: some View {
        Button(action: open) {
            RoundedRectangle(cornerRadius: 14)
                .fill(.quaternary)
                .overlay {
                    if let image {
                        image.resizable().scaledToFill()
                    } else if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "photo.badge.exclamationmark")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.primary.opacity(0.10), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("預覽圖片：\(name)")
        .help(name)
        .overlay(alignment: .topTrailing) {
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(.black.opacity(0.8), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(5)
                .accessibilityLabel("移除圖片：\(name)")
                .help("移除")
            }
        }
    }
}

struct ChatImagePreviewSurface: View {
    let image: Image?
    let imageSize: CGSize
    let name: String
    var zoom: CGFloat = 1
    var isLoading = false
    var error: String?
    var canGoBack = false
    var canGoForward = false
    var canSave = true
    let close: () -> Void
    let save: () -> Void
    let zoomOut: () -> Void
    let zoomIn: () -> Void
    let previous: () -> Void
    let next: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.88)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                imageViewport(in: CGSize(
                    width: max(1, geometry.size.width - 112),
                    height: max(1, geometry.size.height - 144)))
                    .padding(.horizontal, 56)
                    .padding(.vertical, 72)
                VStack {
                    HStack(spacing: 8) {
                        Spacer()
                        control("arrow.down.to.line", label: "下載圖片", action: save)
                            .disabled(!canSave || image == nil)
                        control("xmark", label: "關閉預覽", action: close)
                    }
                    Spacer()
                    HStack(spacing: 0) {
                        control("minus", label: "縮小", action: zoomOut)
                            .disabled(zoom <= 0.25 || image == nil)
                        Text("\(Int(zoom * 100))%")
                            .font(.system(size: 13).monospacedDigit())
                            .frame(width: 72)
                        control("plus", label: "放大", action: zoomIn)
                            .disabled(zoom >= 4 || image == nil)
                    }
                    .padding(4)
                    .background(.regularMaterial, in: Capsule())
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 32)
                HStack {
                    if canGoBack {
                        control("arrow.left", label: "上一張圖片", action: previous)
                    }
                    Spacer()
                    if canGoForward {
                        control("arrow.right", label: "下一張圖片", action: next)
                    }
                }
                .padding(.horizontal, 20)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("圖片預覽：\(name)")
            .onExitCommand(perform: close)
        }
    }

    @ViewBuilder private func imageViewport(in size: CGSize) -> some View {
        if let image {
            let ratio = min(size.width / max(1, imageSize.width),
                            size.height / max(1, imageSize.height), 1)
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                image.resizable()
                    .frame(width: max(1, imageSize.width * ratio * zoom),
                           height: max(1, imageSize.height * ratio * zoom))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(minWidth: size.width, minHeight: size.height)
                    .accessibilityLabel(name)
            }
        } else if isLoading {
            ProgressView().tint(.white).accessibilityLabel("載入圖片")
        } else {
            Label(error ?? "無法讀取圖片", systemImage: "photo.badge.exclamationmark")
                .font(.callout)
                .foregroundStyle(.white)
        }
    }

    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}
