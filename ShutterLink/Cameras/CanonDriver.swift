import CoreBluetooth
import Foundation

/// 캐논 BR-E1 리모컨 프로토콜.
/// 참고: furble(CanonEOSRemote), eos-remote-web, Ian Douglas Scott의 분석.
/// - 연결마다 페어 특성(…0002)에 [0x03] + 리모컨 이름(ASCII)을 써서 자신을 알린다
/// - 촬영 특성(…0003)에 1바이트: 버튼 비트 | 모드 비트
///   셔터 0x80, 초점 0x40 / 즉시 0x0C, 2초 지연 0x04, 동영상 0x08
@MainActor
final class CanonDriver: CameraDriver {
    static let serviceUUID = CBUUID(string: "00050000-0000-1000-0000-D8492FFFA821")
    static let pairUUID = CBUUID(string: "00050002-0000-1000-0000-D8492FFFA821")
    static let shootUUID = CBUUID(string: "00050003-0000-1000-0000-D8492FFFA821")

    private static let buttonRelease: UInt8 = 0x80
    private static let buttonFocus: UInt8 = 0x40
    private static let modeImmediate: UInt8 = 0x0C
    private static let modeMovie: UInt8 = 0x08

    let minimumHold: TimeInterval = 0.05
    var onEvent: ((CameraEvent) -> Void)?

    /// 카메라에 표시될 이름 (ASCII, 16자 이하)
    private let remoteName = "ShutterLink"
    private var shoot: CBCharacteristic?

    func setUp(link: PeripheralLink) async throws {
        // 레퍼런스 구현들이 연결 직후 잠시 기다린다 (카메라 쪽 보안 처리 대기)
        try await Task.sleep(for: .seconds(1))
        let chars = try await link.discover(service: Self.serviceUUID,
                                            characteristics: [Self.pairUUID, Self.shootUUID])
        guard let pair = chars[Self.pairUUID] else {
            throw BLEError.characteristicNotFound("Canon pair")
        }
        guard let shoot = chars[Self.shootUUID] else {
            throw BLEError.characteristicNotFound("Canon shoot")
        }
        try await link.write([0x03] + Array(remoteName.utf8), to: pair, timeout: 40)
        self.shoot = shoot
    }

    func press(link: PeripheralLink) async throws {
        guard let shoot else { throw BLEError.notReady }
        try await link.write([Self.buttonRelease | Self.modeImmediate], to: shoot)
    }

    func release(link: PeripheralLink) async throws {
        guard let shoot else { throw BLEError.notReady }
        try await link.write([Self.modeImmediate], to: shoot)
    }

    func focus(_ on: Bool, link: PeripheralLink) async throws {
        guard let shoot else { throw BLEError.notReady }
        try await link.write([(on ? Self.buttonFocus : 0) | Self.modeImmediate], to: shoot)
    }

    func record(_ press: Bool, link: PeripheralLink) async throws {
        guard let shoot else { throw BLEError.notReady }
        try await link.write([(press ? Self.buttonRelease : 0) | Self.modeMovie], to: shoot)
    }

    func handle(value: Data, from uuid: CBUUID) {}
}

/// 캐논 스마트폰(Camera Connect) 모드 — 실험. 참고: furble CanonEOSSmart.
/// 아이폰의 블루투스 본딩을 Camera Connect와 공유하므로 '이 기기 지우기'가 필요 없다.
/// 대신 카메라에 ShutterLink를 스마트폰으로 하나 더 등록한다(카메라에서 승인).
/// 셔터만 된다 (반셔터·녹화 명령은 알려진 게 없음).
@MainActor
final class CanonSmartDriver: CameraDriver {
    static let serviceUUID = CBUUID(string: "00010000-0000-1000-0000-D8492FFFA821")
    private static let nameUUID = CBUUID(string: "00010006-0000-1000-0000-D8492FFFA821")
    private static let idenUUID = CBUUID(string: "0001000A-0000-1000-0000-D8492FFFA821")
    private static let controlServiceUUID = CBUUID(string: "00030000-0000-1000-0000-D8492FFFA821")
    private static let modeUUID = CBUUID(string: "00030010-0000-1000-0000-D8492FFFA821")
    private static let shutterUUID = CBUUID(string: "00030030-0000-1000-0000-D8492FFFA821")

    private static let pairAccept: UInt8 = 0x02
    private static let modeShoot: UInt8 = 0x02

    let minimumHold: TimeInterval = 0.05
    var onEvent: ((CameraEvent) -> Void)?
    var supportsFocus: Bool { false }
    /// 처음 등록할 때만 카메라의 승인을 기다린다 (재연결 땐 승인된 것으로 본다 — furble과 동일)
    var isNewPairing = false

    private let appID: [UInt8]
    private let remoteName = Array("ShutterLink".utf8)
    private var shutter: CBCharacteristic?

    init(appID: [UInt8]) {
        self.appID = appID
    }

    func setUp(link: PeripheralLink) async throws {
        let chars = try await link.discover(service: Self.serviceUUID,
                                            characteristics: [Self.nameUUID, Self.idenUUID])
        guard let name = chars[Self.nameUUID], let iden = chars[Self.idenUUID] else {
            throw BLEError.characteristicNotFound("Canon 스마트폰 모드")
        }
        // 암호화된 특성: 본딩이 없으면 여기서 iOS 페어링 팝업이 뜬다 (Camera Connect 본딩이 있으면 그대로 씀)
        if name.properties.contains(.indicate) { try await link.setNotify(name) }
        let approval = isNewPairing ? link.expectValue(on: Self.nameUUID) : nil
        try await link.write([0x01] + remoteName, to: name, timeout: 40)
        try await link.writeMany([[0x03] + appID, [0x04] + remoteName, [0x05, 0x02]], to: iden)
        if let approval {
            let reply = try await approval.wait(timeout: 50, label: "카메라 승인")
            guard reply.first == Self.pairAccept else {
                throw BLEError.protocolError("카메라에서 연결을 거부했습니다")
            }
        }
        try await link.write([0x01], to: iden)

        let control = try await link.discover(service: Self.controlServiceUUID,
                                              characteristics: [Self.modeUUID, Self.shutterUUID])
        guard let mode = control[Self.modeUUID], let shutter = control[Self.shutterUUID] else {
            throw BLEError.characteristicNotFound("Canon 스마트폰 모드 셔터")
        }
        try await link.write([Self.modeShoot], to: mode)
        self.shutter = shutter
        isNewPairing = false
    }

    func press(link: PeripheralLink) async throws {
        guard let shutter else { throw BLEError.notReady }
        try await link.write([0x00, 0x01], to: shutter)
    }

    func release(link: PeripheralLink) async throws {
        guard let shutter else { throw BLEError.notReady }
        try await link.write([0x00, 0x02], to: shutter)
    }

    func focus(_ on: Bool, link: PeripheralLink) async throws {}

    func record(_ press: Bool, link: PeripheralLink) async throws {
        guard press else { return }
        throw BLEError.protocolError("스마트폰 모드는 녹화를 지원하지 않습니다")
    }

    func handle(value: Data, from uuid: CBUUID) {}
}
