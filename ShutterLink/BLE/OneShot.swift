import Foundation

/// BLE 콜백 하나를 async/await로 기다리기 위한 1회성 대기 객체.
/// 타임아웃·연결 끊김 등 어느 쪽이 먼저 오든 정확히 한 번만 완료된다.
@MainActor
final class OneShot<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var earlyResult: Result<Value, Error>?
    private var timer: Task<Void, Never>?
    private(set) var isDone = false

    func wait(timeout: TimeInterval, label: String) async throws -> Value {
        if let earlyResult { return try earlyResult.get() }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Value, Error>) in
            self.continuation = c
            self.timer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self?.complete(.failure(BLEError.timeout(label)))
            }
        }
    }

    func complete(_ result: Result<Value, Error>) {
        guard !isDone else { return }
        isDone = true
        timer?.cancel()
        timer = nil
        if let c = continuation {
            continuation = nil
            c.resume(with: result)
        } else {
            earlyResult = result
        }
    }
}

enum BLEError: LocalizedError {
    case timeout(String)
    case serviceNotFound(String)
    case characteristicNotFound(String)
    case disconnected
    case notReady
    case protocolError(String)
    case servicesChanged

    var errorDescription: String? {
        switch self {
        case .timeout(let step): return "\(step) 응답 시간 초과"
        case .serviceNotFound(let s): return "카메라 서비스를 찾지 못했습니다 (\(s)). 카메라가 리모컨 모드인지 확인하세요."
        case .characteristicNotFound(let c): return "카메라 기능을 찾지 못했습니다 (\(c))"
        case .disconnected: return "연결이 끊어졌습니다"
        case .notReady: return "카메라가 아직 준비되지 않았습니다"
        case .protocolError(let m): return m
        case .servicesChanged: return "카메라 GATT 구성이 바뀌었습니다"
        }
    }
}

extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
