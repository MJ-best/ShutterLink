import CoreBluetooth
import SwiftUI

struct ContentView: View {
    @Environment(BLEController.self) private var ble
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("selfTimer") private var selfTimer = 0
    @AppStorage("keepScreenOn") private var keepScreenOn = true
    @AppStorage("haptics") private var hapticsOn = true
    @AppStorage("videoMode") private var videoMode = false

    @State private var showPairing = false
    @State private var showSettings = false
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var flash = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                bluetoothBanner

                if ble.sessions.isEmpty {
                    emptyState
                } else {
                    cameraList
                }

                Spacer(minLength: 8)

                ShutterButton(enabled: shutterEnabled, countdown: countdown,
                              halfPressed: ble.focusHeld, focusLocked: ble.focusConfirmed,
                              recording: ble.recordingSince != nil,
                              onPress: handlePress, onRelease: handleRelease)

                if !videoMode { focusButton }

                statusLine

                if !videoMode {
                    Picker("셀프타이머", selection: $selfTimer) {
                        Text("타이머 끔").tag(0)
                        Text("2초").tag(2)
                        Text("5초").tag(5)
                        Text("10초").tag(10)
                    }
                    .pickerStyle(.segmented)
                    .disabled(countdown != nil)
                }

                Picker("촬영 모드", selection: $videoMode) {
                    Text("사진").tag(false)
                    Text("동영상").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(countdown != nil || ble.recordingSince != nil)
                .onChange(of: videoMode) { _, _ in ble.shutterUp() }   // 반셔터 등을 풀고 전환
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .navigationTitle("셔터링크")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("설정")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPairing = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("카메라 추가")
                }
            }
            .sheet(isPresented: $showPairing) { PairingView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
        .overlay {
            Color.white
                .opacity(flash ? 0.28 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.15), value: flash)
        }
        .onChange(of: ble.confirmedShots) { _, _ in
            if hapticsOn { Haptics.confirmed() }
            flash = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(90))
                flash = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                ble.reconnectAll()
            } else {
                // 앱을 벗어나면 눌린 셔터를 반드시 놓는다 (연사·벌브가 계속되지 않게)
                ble.shutterUp()
                cancelCountdown()
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = keepScreenOn }
        .onChange(of: keepScreenOn) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
    }

    // MARK: - 셔터

    private var shutterEnabled: Bool {
        countdown != nil || !ble.readyArmedSessions.isEmpty || ble.recordingSince != nil
    }

    private func handlePress() {
        if hapticsOn { Haptics.press() }
        guard !videoMode, selfTimer == 0 else { return }   // 동영상·타이머는 손을 뗄 때 동작
        ble.shutterDown()
    }

    private func handleRelease() {
        if videoMode {
            ble.toggleRecording()
            return
        }
        guard selfTimer == 0 else {
            if countdownTask != nil { cancelCountdown() } else { startCountdown() }
            return
        }
        ble.shutterUp()
    }

    private func startCountdown() {
        let seconds = selfTimer
        countdownTask = Task { @MainActor in
            for n in stride(from: seconds, to: 0, by: -1) {
                countdown = n
                if hapticsOn { Haptics.tick() }
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            countdown = nil
            countdownTask = nil
            ble.shutterDown()
            try? await Task.sleep(for: .milliseconds(80))
            ble.shutterUp()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    // MARK: - 하위 뷰

    @ViewBuilder
    private var bluetoothBanner: some View {
        if let message = ble.bluetoothMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("등록된 카메라 없음", systemImage: "camera")
        } description: {
            Text("카메라를 리모컨 페어링 모드로 두고 추가하세요.\n한 번 등록하면 다음부터는 카메라만 켜면 자동으로 연결됩니다.")
        } actions: {
            Button("카메라 추가") { showPairing = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var cameraList: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(ble.sessions) { session in
                    CameraRow(session: session)
                }
            }
        }
        .frame(maxHeight: 300)
        .scrollBounceBehavior(.basedOnSize)
    }

    private var focusButton: some View {
        Button {
            if hapticsOn { Haptics.tick() }
            ble.toggleFocus()
        } label: {
            Label(ble.focusHeld ? "반셔터 해제" : "반셔터 (초점 맞추기)", systemImage: "viewfinder")
                .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(ble.focusHeld ? (ble.focusConfirmed ? .green : .yellow) : .secondary)
        .disabled(!ble.canFocus || countdown != nil)
    }

    private var statusLine: some View {
        Group {
            if let countdown {
                Text("\(countdown)초 후 촬영 · 다시 누르면 취소")
            } else if ble.readyArmedSessions.isEmpty {
                Text(ble.sessions.isEmpty ? " " : "연결된 촬영 대상 카메라가 없습니다")
            } else if videoMode {
                if let since = ble.recordingSince {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text("● 녹화 중 \(Duration.seconds(context.date.timeIntervalSince(since)).formatted(.time(pattern: .minuteSecond))) · 탭하면 정지")
                            .foregroundStyle(.red)
                    }
                } else {
                    Text("탭하면 녹화 시작 · 카메라가 동영상 모드여야 하는 기종도 있습니다")
                }
            } else if ble.focusHeld {
                Text(ble.focusConfirmed ? "초점 맞음 · 셔터를 누르면 촬영" : "반셔터 누름 · 셔터를 누르면 촬영")
            } else if selfTimer > 0 {
                Text("눌렀다 떼면 \(selfTimer)초 타이머 시작")
            } else {
                Text(latencyText)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private var latencyText: String {
        let latencies = ble.readyArmedSessions.compactMap(\.lastLatencyMs)
        let base = "누르는 동안 셔터 누름 · 길게 누르면 연사/벌브"
        guard let worst = latencies.max() else { return base }
        return "응답 \(worst)ms · " + base
    }
}
