import SwiftUI

/// 손가락이 닿는 순간 "누름", 떼는 순간 "뗌"을 보낸다 (탭 인식 지연 없음).
/// 전화 수신·제어센터 등으로 제스처가 취소돼도 반드시 "뗌"을 보낸다.
struct ShutterButton: View {
    var enabled: Bool
    var countdown: Int?
    /// 반셔터(초점) 누름 중 — 링 색과 뷰파인더 표시로 보여준다
    var halfPressed = false
    var focusLocked = false
    var recording = false
    var onPress: @MainActor () -> Void
    var onRelease: @MainActor () -> Void

    @State private var pressing = false
    @GestureState private var touching = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(ringColor, lineWidth: 6)
            RoundedRectangle(cornerRadius: recording ? 18 : 101)
                .fill(fillColor)
                .frame(width: recording ? 96 : 202, height: recording ? 96 : 202)
                .scaleEffect(pressing ? 0.9 : halfPressed ? 0.95 : 1)
            if let countdown {
                Text("\(countdown)")
                    .font(.system(size: 88, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
            } else if halfPressed {
                Image(systemName: "viewfinder")
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: 230, height: 230)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { _ in
                    guard enabled, !pressing else { return }
                    pressing = true
                    onPress()
                }
                .onEnded { _ in endPress() }
        )
        // onEnded가 오지 않는 취소 상황에서도 GestureState는 false로 돌아온다
        .onChange(of: touching) { _, isTouching in
            if !isTouching { endPress() }
        }
        .animation(.easeOut(duration: 0.07), value: pressing)
        .animation(.default, value: countdown)
        .animation(.easeOut(duration: 0.15), value: halfPressed)
        .animation(.easeOut(duration: 0.15), value: focusLocked)
        .animation(.spring(duration: 0.3), value: recording)
        .accessibilityElement()
        .accessibilityLabel("셔터")
        .accessibilityValue(recording ? "녹화 중" : halfPressed ? (focusLocked ? "초점 맞음" : "반셔터 누름") : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            guard enabled else { return }
            onPress()
            onRelease()
        }
    }

    private func endPress() {
        guard pressing else { return }
        pressing = false
        onRelease()
    }

    private var ringColor: Color {
        guard enabled else { return .white.opacity(0.2) }
        guard halfPressed else { return .white.opacity(0.9) }
        return focusLocked ? .green : .yellow
    }

    private var fillColor: Color {
        guard enabled else { return Color.gray.opacity(0.25) }
        return pressing ? Color.red.opacity(0.7) : Color.red
    }
}
