import SwiftUI

struct PairingView: View {
    @Environment(BLEController.self) private var ble
    @Environment(\.dismiss) private var dismiss
    @State private var guideBrand: CameraBrand = .sony

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("기종", selection: $guideBrand) {
                        ForEach(CameraBrand.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)

                    ForEach(Array(guideBrand.pairingSteps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.subheadline.bold())
                                .foregroundStyle(guideBrand.tint)
                                .frame(width: 18)
                            Text(step).font(.subheadline)
                        }
                    }
                    Text(guideBrand.pairingNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("1. 카메라를 리모컨 페어링 대기 상태로")
                }

                Section {
                    if let message = ble.bluetoothMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    } else if ble.discovered.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("주변 카메라를 찾는 중…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(ble.discovered) { camera in
                        Button { ble.pair(camera) } label: { DiscoveredRow(camera: camera) }
                            .disabled(ble.pairing.isBusy || !camera.kind.isPairable)
                    }
                } header: {
                    Text("2. 찾은 카메라를 탭")
                } footer: {
                    Text("카메라와 아이폰을 가까이 두고 진행하세요. 아이폰에 '블루투스 페어링 요청'이 뜨면 '페어링'을 누르세요.")
                }
            }
            .navigationTitle("카메라 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .overlay { progressOverlay }
            .onAppear { ble.startPairingScan() }
            .onDisappear {
                ble.stopPairingScan()
                ble.resetPairingStatus()
            }
            .onChange(of: ble.pairing) { _, status in
                if case .success = status {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.2))
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var progressOverlay: some View {
        switch ble.pairing {
        case .idle:
            EmptyView()
        case .connecting(let name), .preparing(let name):
            OverlayCard {
                ProgressView().controlSize(.large)
                Text("\(name) 연결 중").font(.headline)
                Text("아이폰에 페어링 요청이 뜨면 '페어링'을, 카메라에 확인이 뜨면 OK를 누르세요.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .success(let name):
            OverlayCard {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("\(name) 등록 완료").font(.headline)
            }
        case .failed(let message):
            OverlayCard {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.red)
                Text("연결 실패").font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("다시 시도") { ble.resetPairingStatus() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct OverlayCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 14) { content }
                .padding(24)
                .frame(maxWidth: 320)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}

struct DiscoveredRow: View {
    let camera: DiscoveredCamera

    var body: some View {
        HStack(spacing: 12) {
            BrandBadge(brand: camera.kind.brand)
            VStack(alignment: .leading, spacing: 3) {
                Text(camera.name).font(.headline).foregroundStyle(.primary)
                Text(camera.kind.hint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            SignalBars(rssi: camera.rssi)
        }
        .padding(.vertical, 2)
    }
}

struct SignalBars: View {
    let rssi: Int

    private var level: Int {
        switch rssi {
        case (-60)...: 4
        case (-70)...: 3
        case (-80)...: 2
        default: 1
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= level ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: 4, height: CGFloat(4 + i * 3))
            }
        }
        .accessibilityLabel("신호 \(level)/4")
    }
}
