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
    private static let modeImmediate: UInt8 = 0x0C

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

    func handle(value: Data, from uuid: CBUUID) {}
}
