import CoreBluetooth
import Foundation
import Observation

struct DiscoveredCamera: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var kind: AdvertisedCamera
    var rssi: Int
}

enum PairingProgress: Equatable {
    case idle
    case connecting(String)
    case preparing(String)
    case success(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .connecting, .preparing: true
        default: false
        }
    }
}

/// 앱 전체의 블루투스 중앙 관리자.
/// - 소니·캐논: 저장된 identifier로 "보류 연결(pending connect)"을 걸어두면 카메라가 켜지는 즉시 iOS가 붙여준다.
/// - 니콘: 재연결 광고(제조사 데이터에 우리 ID)를 스캔으로 찾아 연결한다.
@MainActor
@Observable
final class BLEController: NSObject, CBCentralManagerDelegate {
    var bluetoothState: CBManagerState = .unknown
    var sessions: [CameraSession] = []
    var discovered: [DiscoveredCamera] = []
    var pairing: PairingProgress = .idle
    /// 셔터가 실제로 열렸다고 카메라가 알려줄 때마다 증가 (화면 플래시용)
    var confirmedShots = 0

    private let store = CameraStore()
    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var pairingSession: CameraSession?
    /// 저장된 카메라를 다시 페어링하는 동안 잠시 빼둔 기존 세션 (실패하면 되돌린다)
    @ObservationIgnored private var replacedSession: CameraSession?
    @ObservationIgnored private var pairingTimeout: Task<Void, Never>?
    @ObservationIgnored private var wantsPairingScan = false
    @ObservationIgnored private var currentScan: ScanMode?
    @ObservationIgnored private var lastSeen: [UUID: Date] = [:]

    private enum ScanMode: Equatable { case all, nikonOnly }

    /// 자동 재시도 상한 (그 뒤엔 앱을 다시 열거나 '다시 연결'을 눌렀을 때만)
    private static let maxAutoRetries = 8

    override init() {
        super.init()
        sessions = store.load().map { makeSession($0) }
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "shutterlink.central",
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
    }

    // MARK: - 공개 API

    /// 블루투스를 쓸 수 없을 때 화면에 띄울 안내 (정상이면 nil)
    var bluetoothMessage: String? {
        switch bluetoothState {
        case .poweredOn: nil
        case .poweredOff: "블루투스가 꺼져 있습니다"
        case .unauthorized: "설정 > 셔터링크에서 블루투스 권한을 허용해주세요"
        case .unsupported: "이 기기는 블루투스 LE를 지원하지 않습니다"
        default: "블루투스 준비 중…"
        }
    }

    var readyArmedSessions: [CameraSession] {
        sessions.filter { $0.camera.isArmed && $0.state == .ready }
    }

    func shutterDown() {
        for s in readyArmedSessions { s.pressShutter() }
    }

    func shutterUp() {
        for s in sessions where s.isPressed { s.releaseShutter() }
    }

    /// 앱이 앞으로 올 때 등: 쉬고 있거나 실패한 카메라를 다시 붙인다.
    func reconnectAll() {
        guard central.state == .poweredOn else { return }
        for s in sessions {
            switch s.state {
            case .idle, .failed:
                s.retryCount = 0
                if !s.bondLost { connect(saved: s) }
            default:
                break
            }
        }
        updateScan()
    }

    func toggleArmed(_ s: CameraSession) {
        s.camera.isArmed.toggle()
        persist()
    }

    func rename(_ s: CameraSession, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        s.camera.name = trimmed
        persist()
    }

    func forget(_ s: CameraSession) {
        s.isForgotten = true
        if let p = s.peripheral { central.cancelPeripheralConnection(p) }
        s.endConnection()
        sessions.removeAll { $0 === s }
        persist()
        updateScan()
    }

    func retry(_ s: CameraSession) {
        s.retryCount = 0
        s.bondLost = false
        if let p = s.peripheral, p.state == .connected {
            central.cancelPeripheralConnection(p)   // 끊기면 didDisconnect에서 다시 연결
            return
        }
        if let p = s.peripheral, p.state == .connecting {
            central.cancelPeripheralConnection(p)
        }
        s.endConnection()
        s.state = .idle
        connect(saved: s)
        restartScan()   // 니콘 스캔을 새로 시작해 중복 필터를 초기화
    }

    // MARK: 페어링

    func startPairingScan() {
        if !pairing.isBusy { pairing = .idle }
        wantsPairingScan = true
        discovered = []
        lastSeen = [:]
        updateScan()
    }

    func stopPairingScan() {
        wantsPairingScan = false
        discovered = []
        updateScan()
    }

    func resetPairingStatus() {
        if !pairing.isBusy { pairing = .idle }
    }

    func pair(_ d: DiscoveredCamera) {
        guard pairingSession == nil, central.state == .poweredOn else { return }
        let brand = d.kind.brand
        var camera = SavedCamera(id: d.id, name: d.name, brand: brand)
        if brand == .nikon { camera.nikonIdentity = NikonDriver.makeIdentity() }

        // 같은 카메라를 다시 페어링하는 경우 기존 세션을 잠시 빼둔다 (실패하면 되돌림, 아직 저장 안 함)
        if let old = sessions.first(where: { $0.camera.id == d.id }) {
            old.endConnection()
            old.state = .idle
            sessions.removeAll { $0 === old }
            replacedSession = old
        }

        let s = makeSession(camera)
        s.peripheral = d.peripheral
        s.state = .connecting
        pairingSession = s
        pairing = .connecting(camera.name)
        if d.peripheral.state == .connected {
            handleConnected(d.peripheral)      // 이미 붙어 있으면 didConnect가 다시 오지 않는다
        } else {
            central.connect(d.peripheral, options: nil)
        }

        pairingTimeout?.cancel()
        pairingTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, !Task.isCancelled, self.pairingSession === s else { return }
            self.failPairing("시간 초과 — 카메라가 페어링 대기 상태인지 확인하세요")
        }
    }

    // MARK: - 내부

    private func makeSession(_ camera: SavedCamera) -> CameraSession {
        let s = CameraSession(camera: camera)
        s.onShutterFired = { [weak self] in self?.confirmedShots += 1 }
        s.onLinkFailed = { [weak self, weak s] error in
            guard let self, let s, let p = s.peripheral else { return }
            self.markFailed(s, error: error)
            self.central.cancelPeripheralConnection(p)   // → didDisconnect(.failed) → 재시도 예약
        }
        return s
    }

    /// 스캔을 확실히 새로 시작한다 (중복 필터 초기화)
    private func restartScan() {
        if central.state == .poweredOn, currentScan != nil { central.stopScan() }
        currentScan = nil
        updateScan()
    }

    private func persist() {
        store.save(sessions.map(\.camera))
    }

    private func connect(saved s: CameraSession) {
        guard central.state == .poweredOn, !s.isForgotten else { return }
        switch s.camera.brand {
        case .sony, .canon:
            let p = s.peripheral ?? central.retrievePeripherals(withIdentifiers: [s.camera.id]).first
            guard let p else {
                s.state = .failed("카메라 정보를 찾지 못했습니다. 삭제 후 다시 추가하세요.")
                return
            }
            s.peripheral = p
            if p.state == .connected {
                handleConnected(p)
            } else {
                s.state = .waiting
                // 보류 연결: 타임아웃 없이 카메라가 보이는 순간 연결된다
                central.connect(p, options: nil)
            }
        case .nikon:
            if let p = s.peripheral, p.state == .connected {
                handleConnected(p)
            } else {
                s.state = .waiting   // 재연결 광고를 스캔으로 찾는다
            }
        }
    }

    private func updateScan() {
        guard central.state == .poweredOn else {
            currentScan = nil
            return
        }
        let nikonWaiting = sessions.contains { $0.camera.brand == .nikon && $0.state == .waiting }
        let desired: ScanMode? = wantsPairingScan ? .all : (nikonWaiting ? .nikonOnly : nil)
        guard desired != currentScan else { return }
        central.stopScan()
        currentScan = desired
        switch desired {
        case .all:
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        case .nikonOnly:
            // 중복 허용: 페어링 광고를 먼저 본 카메라의 재연결 광고도 놓치지 않게 (백그라운드에선 iOS가 무시)
            central.scanForPeripherals(withServices: [NikonDriver.serviceUUID],
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        case nil:
            break
        }
    }

    private func session(for p: CBPeripheral) -> CameraSession? {
        sessions.first { s in
            s.peripheral?.identifier == p.identifier || s.camera.id == p.identifier
        }
    }

    private func handleDiscovery(_ p: CBPeripheral, mfg: Data?, services: [CBUUID], name: String?, rssi: Int) {
        // 꺼진 카메라를 목록에서 뺀다 — 주변 기기 광고가 올 때마다 확인 (변화가 있을 때만 배열을 건드림)
        let now = Date()
        let staleIDs = Set(discovered.filter { now.timeIntervalSince(lastSeen[$0.id] ?? .distantPast) > 8 }.map(\.id))
        if !staleIDs.isEmpty {
            discovered.removeAll { staleIDs.contains($0.id) }
        }

        guard let kind = AdvertisementParser.classify(manufacturerData: mfg, serviceUUIDs: services) else { return }

        // 니콘 재연결: 광고 속 device ID가 저장된 identity와 같으면 연결
        if case .nikonKnown(let deviceID) = kind {
            if let s = sessions.first(where: {
                $0.camera.brand == .nikon && $0.state == .waiting
                    && NikonDriver.advertisementMatches(deviceID: deviceID, identity: $0.camera.nikonIdentity)
            }) {
                s.peripheral = p
                s.state = .connecting
                central.connect(p, options: nil)
                updateScan()
            }
            return
        }

        // 페어링 목록: 연결 가능한 카메라 + 안내가 필요한 캐논(리모컨 화면이 아닌 상태)
        guard wantsPairingScan, kind.isPairable || kind == .canonOther else { return }
        // 이미 연결된 카메라는 목록에서 숨김
        if let s = session(for: p), s.state == .ready { return }

        lastSeen[p.identifier] = now
        let displayName = name ?? p.name ?? "\(kind.brand.displayName) 카메라"
        if let i = discovered.firstIndex(where: { $0.id == p.identifier }) {
            let old = discovered[i]
            // 화면이 너무 자주 바뀌지 않게: 상태가 바뀌었거나 신호 세기가 크게 변했을 때만 갱신
            if old.kind != kind || old.name != displayName || abs(old.rssi - rssi) >= 5 {
                discovered[i] = DiscoveredCamera(id: p.identifier, peripheral: p, name: displayName,
                                                 kind: kind, rssi: rssi)
            }
        } else {
            discovered.append(DiscoveredCamera(id: p.identifier, peripheral: p, name: displayName,
                                               kind: kind, rssi: rssi))
        }
    }

    private func handleConnected(_ p: CBPeripheral) {
        if let s = pairingSession, s.peripheral?.identifier == p.identifier {
            Task { await runPairing(s, p) }
            return
        }
        guard let s = session(for: p), !s.isForgotten else {
            central.cancelPeripheralConnection(p)
            return
        }
        s.state = .preparing
        s.beginConnection(p)
        let attempt = s.link
        Task {
            do {
                try await s.prepare()
            } catch {
                // 그 사이 연결이 바뀌었으면(끊김·재연결) 이 시도의 실패는 무시한다
                if let attempt, s.link === attempt, !s.isForgotten {
                    markFailed(s, error: error)
                    central.cancelPeripheralConnection(p)
                }
            }
            updateScan()
        }
    }

    private func runPairing(_ s: CameraSession, _ p: CBPeripheral) async {
        pairing = .preparing(s.camera.name)
        s.beginConnection(p)
        do {
            try await s.prepare()
            guard pairingSession === s else { return }
            pairingTimeout?.cancel()
            pairingSession = nil
            sessions.removeAll { $0.camera.id == s.camera.id }
            sessions.append(s)
            persist()
            replacedSession?.isForgotten = true
            replacedSession = nil
            pairing = .success(s.camera.name)
        } catch {
            guard pairingSession === s else { return }
            failPairing(error.localizedDescription)
        }
    }

    private func failPairing(_ message: String) {
        pairingTimeout?.cancel()
        if let s = pairingSession {
            s.isForgotten = true
            s.endConnection()
            if central.state == .poweredOn, let p = s.peripheral { central.cancelPeripheralConnection(p) }
        }
        pairingSession = nil
        pairing = .failed(message)
        // 다시 페어링하려던 기존 카메라는 목록에 되돌린다
        if let old = replacedSession {
            replacedSession = nil
            sessions.append(old)
            connect(saved: old)
            updateScan()
        }
    }

    /// 카메라 쪽에서 페어링 정보를 지운 경우 — 계속 재시도하면 배터리만 닳고 페어링 팝업이 반복된다.
    private static func isBondLost(_ error: Error?) -> Bool {
        if let e = error as? CBError {
            return e.code == .peerRemovedPairingInformation || e.code == .encryptionTimedOut
        }
        if let e = error as? CBATTError {
            return e.code == .insufficientAuthentication || e.code == .insufficientEncryption
        }
        return false
    }

    private func markFailed(_ s: CameraSession, error: Error?) {
        if Self.isBondLost(error) {
            s.bondLost = true
            s.state = .failed("카메라의 페어링 정보가 사라졌습니다. 아이폰 설정 > Bluetooth에서 지우고 다시 추가하세요.")
        } else {
            s.state = .failed(error?.localizedDescription ?? "연결 실패")
        }
    }

    private func handleDisconnected(_ p: CBPeripheral, error: Error?) {
        if let s = pairingSession, s.peripheral?.identifier == p.identifier {
            failPairing(error?.localizedDescription ?? "카메라가 연결을 끊었습니다")
            return
        }
        guard let s = session(for: p), !s.isForgotten else { return }
        let previous = s.state
        s.endConnection()

        if Self.isBondLost(error) {
            markFailed(s, error: error)
            return
        }

        switch previous {
        case .failed:
            scheduleRetry(s)
        case .preparing:
            // 인증 도중 끊김 = 실패로 보고 간격을 두고 재시도
            s.state = .failed(error?.localizedDescription ?? "인증 중 연결이 끊어졌습니다")
            scheduleRetry(s)
        default:
            // 정상적으로 쓰던 중 끊김(카메라 꺼짐·절전) → 바로 다시 기다린다
            s.state = .waiting
            switch s.camera.brand {
            case .sony, .canon:
                central.connect(p, options: nil)
            case .nikon:
                restartScan()   // 스캔을 새로 시작해 이 카메라의 광고를 다시 받는다
            }
        }
    }

    private func scheduleRetry(_ s: CameraSession, base: Double = 3) {
        guard !s.bondLost, !s.isForgotten else { return }
        s.retryCount += 1
        guard s.retryCount <= Self.maxAutoRetries else { return }
        let delay = min(base * pow(2, Double(s.retryCount - 1)), 300)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !s.isForgotten, case .failed = s.state else { return }
            self.connect(saved: s)
            self.restartScan()
        }
    }

    // MARK: - CBCentralManagerDelegate (메인 큐)

    nonisolated func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        let state = manager.state
        MainActor.assumeIsolated {
            bluetoothState = state
            currentScan = nil
            if state == .poweredOn {
                reconnectAll()
            } else {
                if pairingSession != nil { failPairing("블루투스가 꺼졌습니다") }
                for s in sessions {
                    s.endConnection()
                    s.state = .idle
                }
            }
        }
    }

    nonisolated func centralManager(_ manager: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        var services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        services += advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            handleDiscovery(peripheral, mfg: mfg, services: services, name: localName, rssi: rssi)
        }
    }

    nonisolated func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            handleConnected(peripheral)
        }
    }

    nonisolated func centralManager(_ manager: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            if let s = pairingSession, s.peripheral?.identifier == peripheral.identifier {
                failPairing(error?.localizedDescription ?? "연결 실패")
                return
            }
            guard let s = session(for: peripheral), !s.isForgotten else { return }
            markFailed(s, error: error)
            scheduleRetry(s)
        }
    }

    nonisolated func centralManager(_ manager: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            handleDisconnected(peripheral, error: error)
        }
    }

    /// 백그라운드에서 iOS가 앱을 다시 띄웠을 때 기존 연결을 되찾는다.
    nonisolated func centralManager(_ manager: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        MainActor.assumeIsolated {
            for p in peripherals {
                if let s = session(for: p) { s.peripheral = p }
            }
        }
    }
}
