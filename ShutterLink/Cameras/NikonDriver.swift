import CoreBluetooth
import Foundation

/// 니콘 ML-L7 리모컨 프로토콜 (리모컨 모드: 셔터만).
/// 참고: furble(Nikon, NikonBase, NikonRemote) — COOLPIX B600, Z6 III에서 확인됨.
///
/// 핸드셰이크 (페어 특성 …2087, 17바이트 메시지 = stage 1B + timestamp 8B + id 8B):
///   → [01][00 00 00 00 00 00 00 01][identity 8B]
///   ← [02][0 x16]
///   → [03][0 x16]
///   ← [04][00 x8][시리얼 8B]
/// 셔터 특성(…2083): 누름 [02 02], 뗌 [02 00]
///
/// 재연결: 카메라가 제조사 데이터 [99 03][identity 앞 4바이트][00]로 광고하므로
/// 스캔해서 찾은 뒤 같은 identity로 핸드셰이크를 반복한다.
@MainActor
final class NikonDriver: CameraDriver {
    static let serviceUUID = CBUUID(string: "0000DE00-3DD4-4255-8D62-6DC7B9BD5561")
    static let pairUUID = CBUUID(string: "00002087-3DD4-4255-8D62-6DC7B9BD5561")
    static let indicationUUID = CBUUID(string: "00002084-3DD4-4255-8D62-6DC7B9BD5561")
    static let shutterUUID = CBUUID(string: "00002083-3DD4-4255-8D62-6DC7B9BD5561")

    private static let modeShutter: UInt8 = 0x02
    private static let cmdPress: UInt8 = 0x02
    private static let cmdRelease: UInt8 = 0x00

    let minimumHold: TimeInterval = 0.2
    var onEvent: ((CameraEvent) -> Void)?

    /// 8바이트: device ID 4B (첫 바이트 0x01 고정) + nonce 4B. 카메라는 이 값으로 리모컨을 기억한다.
    let identity: [UInt8]
    private var shutter: CBCharacteristic?

    init(identity: [UInt8]) {
        self.identity = identity.count == 8 ? identity : NikonDriver.makeIdentity()
    }

    static func makeIdentity() -> [UInt8] {
        var bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = 0x01   // 리모컨 모드 device ID는 항상 0x01로 시작
        return bytes
    }

    func setUp(link: PeripheralLink) async throws {
        let chars = try await link.discover(service: Self.serviceUUID,
                                            characteristics: [Self.pairUUID, Self.indicationUUID, Self.shutterUUID])
        guard let pair = chars[Self.pairUUID] else {
            throw BLEError.characteristicNotFound("Nikon pair (ML-L7 모드인지 확인)")
        }
        guard let shutter = chars[Self.shutterUUID] else {
            throw BLEError.characteristicNotFound("Nikon shutter")
        }
        if let ind = chars[Self.indicationUUID] {
            try await link.setNotify(ind)
        }
        try await link.setNotify(pair)

        // Stage 1 → 2 (카메라가 stage 0을 보내면 stage 1을 한 번 다시 보낸다 — furble과 동일)
        let stage1: [UInt8] = [0x01] + [0, 0, 0, 0, 0, 0, 0, 0x01] + identity
        var r2 = try await exchange(stage1, on: pair, link: link, label: "니콘 인증 2단계")
        if r2.first == 0x00 {
            r2 = try await exchange(stage1, on: pair, link: link, label: "니콘 인증 2단계")
        }
        guard r2.first == 0x02 else {
            throw BLEError.protocolError("니콘 인증 2단계 응답이 예상과 다릅니다: \(r2.hex)")
        }

        // Stage 3 → 4
        let stage3: [UInt8] = [0x03] + Array(repeating: 0, count: 16)
        let r4 = try await exchange(stage3, on: pair, link: link, label: "니콘 인증 4단계")
        guard r4.first == 0x04 else {
            throw BLEError.protocolError("니콘 인증 4단계 응답이 예상과 다릅니다: \(r4.hex)")
        }
        self.shutter = shutter
    }

    /// 쓰기 전에 응답을 예약해 두고(놓치지 않게) 보낸 뒤 인디케이션을 기다린다.
    private func exchange(_ message: [UInt8], on pair: CBCharacteristic,
                          link: PeripheralLink, label: String) async throws -> [UInt8] {
        let reply = link.expectValue(on: Self.pairUUID)
        try await link.write(message, to: pair)
        return [UInt8](try await reply.wait(timeout: 10, label: label))
    }

    func press(link: PeripheralLink) async throws {
        guard let shutter else { throw BLEError.notReady }
        try await link.write([Self.modeShutter, Self.cmdPress], to: shutter)
    }

    func release(link: PeripheralLink) async throws {
        guard let shutter else { throw BLEError.notReady }
        try await link.write([Self.modeShutter, Self.cmdRelease], to: shutter)
    }

    func handle(value: Data, from uuid: CBUUID) {}

    /// 재연결 광고가 이 리모컨(identity)을 찾는 것인지
    static func advertisementMatches(deviceID: [UInt8], identity: [UInt8]?) -> Bool {
        guard let identity, identity.count >= 4 else { return false }
        return deviceID == Array(identity.prefix(4))
    }
}
