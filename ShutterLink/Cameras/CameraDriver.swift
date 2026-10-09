import CoreBluetooth
import Foundation

enum CameraEvent {
    case shutterFired
    case focus(Bool)
    case info(String)
}

/// 브랜드별 리모컨 프로토콜. 카메라 입장에서는 "물리 리모컨의 셔터 버튼"을 누르고 떼는 것과 같다.
@MainActor
protocol CameraDriver: AnyObject {
    /// 누름→뗌 사이 최소 유지 시간 (너무 짧게 떼면 무시하는 기종 대비)
    var minimumHold: TimeInterval { get }
    var onEvent: ((CameraEvent) -> Void)? { get set }

    /// 연결 직후 서비스 검색·인증·핸드셰이크
    func setUp(link: PeripheralLink) async throws
    func press(link: PeripheralLink) async throws
    func release(link: PeripheralLink) async throws
    func handle(value: Data, from uuid: CBUUID)
}
