import SwiftUI

struct SettingsView: View {
    @Environment(BLEController.self) private var ble
    @Environment(\.dismiss) private var dismiss
    @AppStorage("keepScreenOn") private var keepScreenOn = true
    @AppStorage("haptics") private var hapticsOn = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("앱을 켜둔 동안 화면 꺼짐 방지", isOn: $keepScreenOn)
                    Toggle("진동 피드백", isOn: $hapticsOn)
                }

                Section {
                    Button("모든 카메라 다시 연결") { ble.reconnectAll() }
                } footer: {
                    Text("소니·캐논은 카메라를 켜는 순간 자동으로 붙습니다. 니콘은 '무선 리모컨 연결'이 켬 상태여야 합니다.")
                }

                Section("멀리서 찍을 때") {
                    Label("폰과 카메라 사이에 몸·벽이 없을수록 멀리 갑니다", systemImage: "antenna.radiowaves.left.and.right")
                    Label("카메라 절전 시간을 길게 하면 연결이 끊기지 않습니다", systemImage: "moon.zzz")
                    Label("화면이 잠겨도 연결은 유지됩니다 (다시 열면 바로 촬영)", systemImage: "lock")
                }
                .font(.subheadline)

                Section("정보") {
                    Text("소니·캐논·니콘의 순정 블루투스 리모컨 프로토콜을 사용합니다. 각 브랜드와 무관한 비공식 앱입니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
    }
}
