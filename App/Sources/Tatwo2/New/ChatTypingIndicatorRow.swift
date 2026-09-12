import SwiftUI

/// iPhone 訊息式的「對方正在輸入」：三顆有節奏的點，出現在最新一則 AI 訊息還沒有文字的時候。
/// 只在回合進行中且串流文字還沒到之前顯示；文字一到就換成真正的訊息氣泡。
struct ChatTypingIndicatorRow: View {
    let route: ChatRouteChoice
    let rowWidth: CGFloat?
    var body: some View {
        // 2026-09-11 使用者：打字泡泡太高 → 底部對齊 AI 頭像底部。
        HStack(alignment: .bottom, spacing: 10) {
            ChatModelAvatar(route: route)
            // 2026-09-11 使用者：再縮小。
            ChatTypingDots()
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(
                Color.primary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Spacer(minLength: 0)
        }
        .frame(width: rowWidth, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(route.title) 正在回覆")
    }
}

/// Fixed-size dots shared by the empty-reply row and expandable work history.
struct ChatTypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary.opacity(phase == i ? 0.92 : 0.38))
                    .frame(width: 3, height: 3)
            }
        }
        .frame(width: 15, height: 8)
        .accessibilityHidden(true)
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(340)) }
                catch { return }
                withAnimation(.easeInOut(duration: 0.3)) { phase = (phase + 1) % 3 }
            }
        }
    }
}
