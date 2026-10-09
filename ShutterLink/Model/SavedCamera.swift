import Foundation

/// 페어링이 끝난 카메라. 아이폰에 저장되어 앱을 켤 때마다 자동으로 다시 붙는다.
struct SavedCamera: Codable, Identifiable, Hashable {
    /// 페어링 당시의 CBPeripheral.identifier (소니·캐논은 이걸로 바로 재연결)
    var id: UUID
    var name: String
    var brand: CameraBrand
    /// 니콘 전용: 카메라가 리모컨을 기억하는 8바이트 ID
    var nikonIdentity: [UInt8]?
    /// 셔터를 누를 때 함께 촬영할지 (여러 대 동시 촬영)
    var isArmed: Bool = true
}

/// UserDefaults(JSON)에 카메라 목록 저장
struct CameraStore {
    private let key = "savedCameras.v1"
    private let defaults = UserDefaults.standard

    func load() -> [SavedCamera] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedCamera].self, from: data)) ?? []
    }

    func save(_ cameras: [SavedCamera]) {
        if let data = try? JSONEncoder().encode(cameras) {
            defaults.set(data, forKey: key)
        }
    }
}
