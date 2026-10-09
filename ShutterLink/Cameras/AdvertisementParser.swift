import CoreBluetooth
import Foundation

/// 광고 패킷만 보고 어떤 카메라가 어떤 상태인지 판별한다.
enum AdvertisedCamera: Equatable {
    /// 소니: 제조사 데이터 2D 01 03 00 ... (pairing/remote 비트는 못 읽으면 nil)
    case sony(pairingEnabled: Bool?, remoteEnabled: Bool?)
    /// 캐논: BR-E1 리모컨 서비스 UUID를 광고 중 (리모컨 페어링 대기)
    case canonRemotePairing
    /// 캐논이지만 리모컨 페어링 화면이 아님
    case canonOther
    /// 니콘: 서비스 UUID만 있고 제조사 데이터 없음 = ML-L7 페어링 대기
    case nikonPairing
    /// 니콘: 이미 어떤 리모컨과 페어링된 상태로 재연결 광고 (device ID 4바이트)
    case nikonKnown(deviceID: [UInt8])

    var brand: CameraBrand {
        switch self {
        case .sony: .sony
        case .canonRemotePairing, .canonOther: .canon
        case .nikonPairing, .nikonKnown: .nikon
        }
    }

    /// 페어링 목록에서 탭해서 연결을 시도할 만한 상태인지
    var isPairable: Bool {
        switch self {
        case .sony, .canonRemotePairing, .nikonPairing: true
        case .canonOther, .nikonKnown: false
        }
    }

    var hint: String {
        switch self {
        case .sony(let pairing, let remote):
            if remote == false { return "카메라에서 'Bluetooth 리모컨'을 켜세요" }
            if pairing == true { return "페어링 대기 중 · 탭해서 연결" }
            if pairing == false { return "카메라에서 '페어링'을 실행하세요 (이미 등록된 경우 탭)" }
            return "탭해서 연결"
        case .canonRemotePairing: return "리모컨 페어링 대기 중 · 탭해서 연결"
        case .canonOther: return "리모컨 페어링 화면을 열어주세요"
        case .nikonPairing: return "ML-L7 페어링 대기 중 · 탭해서 연결"
        case .nikonKnown: return "다른 리모컨에 등록된 상태"
        }
    }
}

@MainActor
enum AdvertisementParser {
    static let sonyCompanyID: UInt16 = 0x012D
    static let canonCompanyID: UInt16 = 0x01A9
    static let nikonCompanyID: UInt16 = 0x0399

    static func classify(manufacturerData: Data?, serviceUUIDs: [CBUUID]) -> AdvertisedCamera? {
        let mfg = manufacturerData.map { [UInt8]($0) } ?? []
        let company: UInt16? = mfg.count >= 2 ? UInt16(mfg[0]) | (UInt16(mfg[1]) << 8) : nil

        // 니콘 (서비스 UUID가 결정적)
        if serviceUUIDs.contains(NikonDriver.serviceUUID) {
            if company == nikonCompanyID, mfg.count >= 6 {
                return .nikonKnown(deviceID: Array(mfg[2..<6]))
            }
            if mfg.isEmpty { return .nikonPairing }
        }

        // 캐논 리모컨 페어링
        if serviceUUIDs.contains(CanonDriver.serviceUUID) {
            return .canonRemotePairing
        }

        // 소니: 2D 01 | 03 00 (카메라)
        if company == sonyCompanyID, mfg.count >= 4, mfg[2] == 0x03, mfg[3] == 0x00 {
            let mode = sonyMode22(mfg)
            // 0x40 = 페어링 대기 (furble·alpharemote 공통). 리모컨 활성 비트는 기종마다 달라(0x02/0x04) 판단하지 않는다.
            let pairing = mode.map { ($0 & 0x40) != 0 }
            return .sony(pairingEnabled: pairing, remoteEnabled: nil)
        }

        if company == canonCompanyID { return .canonOther }
        return nil
    }

    /// 소니 광고의 태그 0x22 다음 바이트(상태 비트). 보통 오프셋 8에 있지만 기종차를 대비해 검색한다.
    private static func sonyMode22(_ b: [UInt8]) -> UInt8? {
        guard b.count > 9 else { return nil }
        for i in 8..<(b.count - 1) where b[i] == 0x22 {
            return b[i + 1]
        }
        return nil
    }
}
