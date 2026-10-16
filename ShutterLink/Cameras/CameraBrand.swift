import SwiftUI

enum CameraBrand: String, Codable, CaseIterable, Identifiable {
    case sony, canon, nikon

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sony: "소니"
        case .canon: "캐논"
        case .nikon: "니콘"
        }
    }

    var badgeLetter: String {
        switch self {
        case .sony: "S"
        case .canon: "C"
        case .nikon: "N"
        }
    }

    var tint: Color {
        switch self {
        case .sony: Color(red: 0.85, green: 0.45, blue: 0.10)
        case .canon: Color(red: 0.80, green: 0.10, blue: 0.15)
        case .nikon: Color(red: 0.95, green: 0.78, blue: 0.10)
        }
    }

    /// 카메라를 리모컨 페어링 대기 상태로 만드는 순서 (메뉴 이름은 기종·펌웨어마다 조금 다를 수 있음)
    var pairingSteps: [String] {
        switch self {
        case .sony:
            [
                "MENU → 네트워크 → 'Bluetooth 리모컨'을 '켬'",
                "네트워크 → Bluetooth 설정 → 'Bluetooth 기능'을 '켬'",
                "같은 메뉴에서 '페어링' 실행 (카메라가 대기 화면으로 바뀜)",
                "아래 목록에서 소니 카메라를 탭 → 아이폰의 '블루투스 페어링 요청'에서 '페어링' → 카메라에서 확인",
            ]
        case .canon:
            [
                "MENU → 네트워크(무선 설정) → '무선 리모컨 연결' 또는 'Bluetooth 기능 → 리모컨'",
                "'기기 추가'/'페어링'을 선택해 리모컨(BR-E1) 페어링 대기 화면 띄우기",
                "아래 목록에서 캐논 카메라를 탭",
                "아이폰이나 카메라에 확인 메시지가 뜨면 승인",
            ]
        case .nikon:
            [
                "네트워크 메뉴 → '무선 리모컨(ML-L7) 옵션'",
                "'무선 리모컨 저장'을 선택해 페어링 대기",
                "아래 목록에서 니콘 카메라를 탭",
                "다음부터는 같은 메뉴의 '무선 리모컨 연결'이 '켬'이면 자동으로 다시 붙습니다",
            ]
        }
    }

    var pairingNote: String {
        switch self {
        case .sony:
            "a6400은 2019년 여름 이후 펌웨어가 필요합니다. 일부 기종은 리모컨과 위치정보 연동을 동시에 쓸 수 없습니다."
        case .canon:
            "리모컨 모드는 Camera Connect와 블루투스 페어링이 충돌할 수 있습니다. 같이 쓰려면(실험): 카메라의 '스마트폰 연결 → 기기 추가' 대기 화면에서 목록의 '스마트폰 모드' 항목을 탭하고 카메라에서 승인하세요. 이 방식은 셔터만 됩니다."
        case .nikon:
            "니콘 리모컨 모드는 반셔터가 없습니다. 카메라를 AF-S·초점 우선으로 두면 셔터를 누를 때 초점부터 맞춥니다. 리모컨 모드를 켜면 SnapBridge 연결은 끊어집니다."
        }
    }
}
