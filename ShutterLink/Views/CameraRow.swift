import SwiftUI

struct BrandBadge: View {
    let brand: CameraBrand

    var body: some View {
        Text(brand.badgeLetter)
            .font(.system(size: 17, weight: .heavy, design: .rounded))
            .foregroundStyle(.black)
            .frame(width: 36, height: 36)
            .background(brand.tint, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityLabel(brand.displayName)
    }
}

/// 저장된 카메라 한 줄. 탭하면 촬영 대상 켜기/끄기, 길게 누르면 메뉴.
struct CameraRow: View {
    @Environment(BLEController.self) private var ble
    let session: CameraSession

    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    var body: some View {
        Button {
            ble.toggleArmed(session)
        } label: {
            HStack(spacing: 12) {
                BrandBadge(brand: session.camera.brand)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.camera.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if session.state.isBusy {
                    ProgressView().controlSize(.small)
                }
                Image(systemName: session.camera.isArmed ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(session.camera.isArmed ? Color.red : Color.secondary)
                    .accessibilityLabel(session.camera.isArmed ? "촬영 대상" : "촬영 제외")
            }
            .padding(12)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            .opacity(session.camera.isArmed ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { ble.retry(session) } label: { Label("다시 연결", systemImage: "arrow.clockwise") }
            Button {
                newName = session.camera.name
                renaming = true
            } label: { Label("이름 바꾸기", systemImage: "pencil") }
            Button(role: .destructive) { confirmDelete = true } label: { Label("삭제", systemImage: "trash") }
        }
        .alert("이름 바꾸기", isPresented: $renaming) {
            TextField("이름", text: $newName)
            Button("저장") { ble.rename(session, to: newName) }
            Button("취소", role: .cancel) {}
        }
        .confirmationDialog("\(session.camera.name)을(를) 삭제할까요?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("삭제", role: .destructive) { ble.forget(session) }
        } message: {
            Text("다시 쓰려면 페어링을 새로 해야 합니다. 깔끔하게 지우려면 아이폰 설정 > Bluetooth에서도 이 카메라를 지우세요.")
        }
    }

    private var statusText: String {
        var text = session.state.label
        if session.state == .ready {
            if session.focusLocked { text += " · 초점 맞음" }
            if let event = session.lastEvent { text += " · \(event)" }
        }
        return text
    }

    private var statusColor: Color {
        switch session.state {
        case .ready: .green
        case .connecting, .preparing, .waiting: .orange
        case .failed: .red
        case .idle: .gray
        }
    }
}
