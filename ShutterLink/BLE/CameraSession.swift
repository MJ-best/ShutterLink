import CoreBluetooth
import Foundation
import Observation

enum ConnectionState: Equatable {
    case idle
    /// 카메라가 켜지길 기다리는 중 (iOS가 백그라운드에서 연결 시도 유지)
    case waiting
    case connecting
    case preparing
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .idle: "대기"
        case .waiting: "카메라를 켜면 자동 연결"
        case .connecting: "연결 중…"
        case .preparing: "인증 중…"
        case .ready: "촬영 가능"
        case .failed(let m): m
        }
    }

    var isBusy: Bool {
        switch self {
        case .connecting, .preparing: true
        default: false
        }
    }
}

/// 저장된 카메라 한 대의 연결과 셔터 조작.
/// 명령은 직렬 큐로 처리해 "뗌"이 "누름"보다 먼저 나가는 일이 없게 한다.
@MainActor
@Observable
final class CameraSession: Identifiable {
    let id: UUID
    var camera: SavedCamera
    var state: ConnectionState = .idle
    /// 셔터 "누름" 명령을 보내고 카메라가 응답하기까지 걸린 시간
    var lastLatencyMs: Int?
    var lastEvent: String?
    var focusLocked = false
    private(set) var isPressed = false

    let driver: any CameraDriver

    @ObservationIgnored var peripheral: CBPeripheral?
    @ObservationIgnored private(set) var link: PeripheralLink?
    @ObservationIgnored var isForgotten = false
    @ObservationIgnored var onShutterFired: (() -> Void)?
    /// 연결된 상태에서 재설정에 실패했을 때 (컨트롤러가 끊고 재시도 일정을 잡는다)
    @ObservationIgnored var onLinkFailed: ((Error) -> Void)?
    /// 연속 실패 횟수 (재시도 간격을 점점 늘리는 데 사용)
    @ObservationIgnored var retryCount = 0
    /// 카메라 쪽 페어링 정보가 지워져 자동 재시도가 무의미한 상태
    @ObservationIgnored var bondLost = false

    @ObservationIgnored private var opChain: Task<Void, Never>?
    /// 연결이 바뀔 때마다 증가. 이전 연결에서 쌓인 명령이 새 연결에 실행되지 않게 한다.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pressAckAt: Date?
    /// 설정 도중 카메라가 Service Changed를 보냈는지
    @ObservationIgnored private var gattChanged = false

    init(camera: SavedCamera) {
        self.id = camera.id
        self.camera = camera
        self.driver = switch camera.brand {
        case .sony: SonyDriver()
        case .canon: CanonDriver()
        case .nikon: NikonDriver(identity: camera.nikonIdentity ?? NikonDriver.makeIdentity())
        }
        driver.onEvent = { [weak self] event in self?.handle(event) }
    }

    // MARK: - 연결 수명주기

    /// 연결될 때마다 새 GATT 링크를 만든다.
    func beginConnection(_ p: CBPeripheral) {
        generation &+= 1
        peripheral = p
        let l = PeripheralLink(peripheral: p)
        l.onValue = { [weak self] uuid, data in
            self?.driver.handle(value: data, from: uuid)
        }
        l.onServicesModified = { [weak self, weak l] in
            guard let self, let l, self.link === l else { return }
            switch self.state {
            case .preparing:
                // 진행 중인 설정의 대기를 즉시 끝내고 prepare()가 한 번 더 설정하게 한다
                self.gattChanged = true
                l.failAll(BLEError.servicesChanged)
            case .ready:
                // 같은 링크에서 설정만 다시 한다 (끊었다 붙이면 루프가 생길 수 있음)
                Task { @MainActor in
                    do {
                        try await self.prepare()
                    } catch {
                        if self.link === l { self.onLinkFailed?(error) }
                    }
                }
            default:
                break
            }
        }
        link = l
    }

    func prepare() async throws {
        guard let link else { throw BLEError.notReady }
        state = .preparing
        gattChanged = false
        for attempt in 0..<2 {
            do {
                try await driver.setUp(link: link)
                if !gattChanged { break }
            } catch {
                // Service Changed 때문에 끊긴 첫 시도라면 한 번 더 설정한다
                guard gattChanged, attempt == 0, self.link === link else { throw error }
            }
            gattChanged = false
        }
        // 기다리는 사이 연결이 바뀌었거나 삭제됐으면 무효
        guard self.link === link, !isForgotten else { throw BLEError.disconnected }
        state = .ready
        retryCount = 0
        bondLost = false
        lastEvent = nil
    }

    func endConnection() {
        generation &+= 1
        isPressed = false
        focusLocked = false
        pressAckAt = nil
        opChain?.cancel()
        opChain = nil
        link?.failAll(BLEError.disconnected)
        link = nil
    }

    // MARK: - 셔터

    func pressShutter() {
        guard state == .ready, !isPressed, let link else { return }
        isPressed = true
        let started = Date()
        let driver = self.driver
        enqueue { [weak self] in
            self?.pressAckAt = nil
            try await driver.press(link: link)
            self?.pressAckAt = Date()
            self?.lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
        }
    }

    func releaseShutter() {
        guard isPressed, let link else { return }
        isPressed = false
        let driver = self.driver
        enqueue { [weak self] in
            // 최소 유지 시간은 카메라가 "누름"을 받은 시점부터 잰다
            if let ack = self?.pressAckAt {
                let remaining = driver.minimumHold - Date().timeIntervalSince(ack)
                if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            }
            try await driver.release(link: link)
        }
    }

    private func enqueue(_ op: @escaping @MainActor () async throws -> Void) {
        let previous = opChain
        let gen = generation
        opChain = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.generation == gen else { return }
            do {
                try await op()
            } catch is CancellationError {
                // 연결 종료로 취소됨
            } catch {
                guard self.generation == gen else { return }
                self.lastEvent = Self.describe(error)
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        // 소니: 본딩은 됐지만 카메라의 'Bluetooth 리모컨' 설정이 꺼져 있으면 ATT 0x90
        if ns.domain == CBATTErrorDomain && ns.code == 0x90 {
            return "카메라에서 'Bluetooth 리모컨'을 켜세요"
        }
        return "명령 실패: \(error.localizedDescription)"
    }

    private func handle(_ event: CameraEvent) {
        switch event {
        case .shutterFired:
            lastEvent = "촬영 확인"
            onShutterFired?()
        case .focus(let locked):
            focusLocked = locked
        case .info(let text):
            lastEvent = text
        }
    }
}
