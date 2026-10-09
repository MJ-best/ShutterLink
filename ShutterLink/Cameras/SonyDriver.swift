import CoreBluetooth
import Foundation

/// 소니 알파 Bluetooth 리모컨(RMT-P1BT) 프로토콜.
/// 참고: freemote, Greg Leeds, gethypoxic, furble 문서.
/// - 명령 특성 FF01에 [0x01, 버튼코드] 쓰기 (누름 = 코드|1)
/// - 상태 특성 FF02 알림: [?, 0xA0, b] 셔터, [?, 0x3F, b] 초점 (b & 0x20 = 활성)
/// - 반누름 → 완전누름 → 완전뗌 → 반뗌 순서를 지키지 않으면 카메라가 멈출 수 있다.
@MainActor
final class SonyDriver: CameraDriver {
    static let serviceUUID = CBUUID(string: "8000FF00-FF00-FFFF-FFFF-FFFFFFFFFFFF")
    static let commandUUID = CBUUID(string: "FF01")
    static let statusUUID = CBUUID(string: "FF02")

    private static let halfPress: UInt8 = 0x07
    private static let halfRelease: UInt8 = 0x06
    private static let fullPress: UInt8 = 0x09
    private static let fullRelease: UInt8 = 0x08

    /// AF 중 셔터가 실제로 열릴 때까지 기다리는 최대 시간
    private static let shutterWaitLimit: TimeInterval = 2.5

    let minimumHold: TimeInterval = 0.05
    var onEvent: ((CameraEvent) -> Void)?

    private var command: CBCharacteristic?
    private var hasStatus = false
    private var shutterFiredSincePress = false

    func setUp(link: PeripheralLink) async throws {
        let chars = try await link.discover(service: Self.serviceUUID,
                                            characteristics: [Self.commandUUID, Self.statusUUID])
        guard let cmd = chars[Self.commandUUID] else {
            throw BLEError.characteristicNotFound("Sony FF01")
        }
        command = cmd
        hasStatus = false
        if let status = chars[Self.statusUUID] {
            // 암호화된 특성 → 첫 연결이면 여기서 iOS 페어링 팝업이 뜬다
            try await link.setNotify(status)
            hasStatus = true
        }
    }

    func press(link: PeripheralLink) async throws {
        guard let command else { throw BLEError.notReady }
        shutterFiredSincePress = false
        try await link.writeMany([[0x01, Self.halfPress], [0x01, Self.fullPress]], to: command)
    }

    func release(link: PeripheralLink) async throws {
        guard let command else { throw BLEError.notReady }
        if hasStatus && !shutterFiredSincePress {
            // 짧게 탭했는데 아직 AF 중이면, 셔터가 열릴 때까지 버튼을 누른 채로 둔다
            let deadline = Date().addingTimeInterval(Self.shutterWaitLimit)
            while !shutterFiredSincePress && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            if !shutterFiredSincePress {
                onEvent?(.info("셔터 신호 없음 (초점 실패?)"))
            }
        }
        try await link.writeMany([[0x01, Self.fullRelease], [0x01, Self.halfRelease]], to: command)
    }

    func handle(value: Data, from uuid: CBUUID) {
        guard uuid == Self.statusUUID else { return }
        let b = [UInt8](value)
        guard b.count >= 3 else { return }
        let active = (b[2] & 0x20) != 0
        switch b[1] {
        case 0xA0:
            if active {
                shutterFiredSincePress = true
                onEvent?(.shutterFired)
            }
        case 0x3F:
            onEvent?(.focus(active))
        default:
            break
        }
    }
}
