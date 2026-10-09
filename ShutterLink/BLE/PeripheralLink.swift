import CoreBluetooth
import Foundation

/// 연결 1회분의 GATT 작업(검색·쓰기·알림)을 async/await로 감싼 래퍼.
/// 재연결할 때마다 새로 만든다 — 이전 연결의 특성(characteristic) 객체는 무효가 되기 때문.
@MainActor
final class PeripheralLink: NSObject, CBPeripheralDelegate {
    let peripheral: CBPeripheral
    /// 모든 알림/인디케이션 값 (드라이버가 상태 해석에 사용)
    var onValue: ((CBUUID, Data) -> Void)?
    /// 카메라가 GATT 구성을 바꿨다고 알릴 때 (최신 소니 바디는 연결 직후 Service Changed를 보낸다)
    var onServicesModified: (() -> Void)?

    private var discoveredServices: Set<CBUUID> = []
    private var servicesWaiter: OneShot<Void>?
    private var characteristicsWaiters: [CBUUID: OneShot<Void>] = [:]
    private var writeWaiters: [CBUUID: [OneShot<Void>]] = [:]
    private var notifyWaiters: [CBUUID: OneShot<Void>] = [:]
    private var valueWaiters: [CBUUID: [OneShot<Data>]] = [:]

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
        peripheral.delegate = self
    }

    // MARK: - 작업

    /// 서비스와 특성을 검색해 UUID → 특성 맵으로 돌려준다.
    func discover(service serviceUUID: CBUUID,
                  characteristics charUUIDs: [CBUUID],
                  timeout: TimeInterval = 10) async throws -> [CBUUID: CBCharacteristic] {
        if !discoveredServices.contains(serviceUUID) {
            let w = OneShot<Void>()
            servicesWaiter = w
            peripheral.discoverServices([serviceUUID])
            try await w.wait(timeout: timeout, label: "서비스 검색")
            discoveredServices.insert(serviceUUID)
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            throw BLEError.serviceNotFound(serviceUUID.uuidString)
        }

        let w = OneShot<Void>()
        characteristicsWaiters[service.uuid] = w
        peripheral.discoverCharacteristics(charUUIDs, for: service)
        try await w.wait(timeout: timeout, label: "특성 검색")

        var map: [CBUUID: CBCharacteristic] = [:]
        for c in service.characteristics ?? [] { map[c.uuid] = c }
        return map
    }

    func write(_ bytes: [UInt8], to characteristic: CBCharacteristic, timeout: TimeInterval = 5) async throws {
        try await writeMany([bytes], to: characteristic, timeout: timeout)
    }

    /// 여러 패킷을 한 번에 큐에 넣고 모든 응답을 기다린다.
    /// 하나씩 기다리는 것보다 연결 간격(15~30ms)만큼씩 빨라진다. CoreBluetooth가 순서를 보장한다.
    func writeMany(_ packets: [[UInt8]], to characteristic: CBCharacteristic, timeout: TimeInterval = 5) async throws {
        let props = characteristic.properties
        let withResponse = props.contains(.write) || !props.contains(.writeWithoutResponse)
        var waiters: [OneShot<Void>] = []
        for packet in packets {
            if withResponse {
                let w = OneShot<Void>()
                writeWaiters[characteristic.uuid, default: []].append(w)
                waiters.append(w)
                peripheral.writeValue(Data(packet), for: characteristic, type: .withResponse)
            } else {
                peripheral.writeValue(Data(packet), for: characteristic, type: .withoutResponse)
            }
        }
        for w in waiters {
            try await w.wait(timeout: timeout, label: "명령 전송")
        }
    }

    /// 알림/인디케이션 구독. 암호화가 필요한 특성이면 이 시점에 iOS 페어링 팝업이 뜬다.
    func setNotify(_ characteristic: CBCharacteristic, timeout: TimeInterval = 40) async throws {
        if characteristic.isNotifying { return }
        let w = OneShot<Void>()
        notifyWaiters[characteristic.uuid] = w
        peripheral.setNotifyValue(true, for: characteristic)
        try await w.wait(timeout: timeout, label: "알림 구독")
    }

    /// 다음에 들어올 값을 미리 예약한다. 쓰기 *전에* 호출해야 응답을 놓치지 않는다.
    func expectValue(on uuid: CBUUID) -> OneShot<Data> {
        let w = OneShot<Data>()
        valueWaiters[uuid, default: []].append(w)
        return w
    }

    /// 연결이 끊기면 대기 중인 모든 작업을 실패시킨다.
    func failAll(_ error: Error) {
        servicesWaiter?.complete(.failure(error)); servicesWaiter = nil
        characteristicsWaiters.values.forEach { $0.complete(.failure(error)) }
        characteristicsWaiters.removeAll()
        writeWaiters.values.flatMap { $0 }.forEach { $0.complete(.failure(error)) }
        writeWaiters.removeAll()
        notifyWaiters.values.forEach { $0.complete(.failure(error)) }
        notifyWaiters.removeAll()
        valueWaiters.values.flatMap { $0 }.forEach { $0.complete(.failure(error)) }
        valueWaiters.removeAll()
    }

    // MARK: - CBPeripheralDelegate (메인 큐에서 호출됨)

    private static func result(_ error: Error?) -> Result<Void, Error> {
        if let error { return .failure(error) }
        return .success(())
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            servicesWaiter?.complete(Self.result(error))
            servicesWaiter = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            characteristicsWaiters.removeValue(forKey: service.uuid)?.complete(Self.result(error))
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard var queue = writeWaiters[characteristic.uuid], !queue.isEmpty else { return }
            let w = queue.removeFirst()
            writeWaiters[characteristic.uuid] = queue
            w.complete(Self.result(error))
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            notifyWaiters.removeValue(forKey: characteristic.uuid)?.complete(Self.result(error))
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        let ids = invalidatedServices.map(\.uuid)
        MainActor.assumeIsolated {
            ids.forEach { discoveredServices.remove($0) }
            onServicesModified?()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        let data = characteristic.value ?? Data()
        let uuid = characteristic.uuid
        MainActor.assumeIsolated {
            if error == nil, var queue = valueWaiters[uuid] {
                // 시간 초과로 끝난 대기는 건너뛴다 (다음 응답을 삼키지 않게)
                while let first = queue.first, first.isDone { queue.removeFirst() }
                if !queue.isEmpty { queue.removeFirst().complete(.success(data)) }
                valueWaiters[uuid] = queue
            }
            if error == nil { onValue?(uuid, data) }
        }
    }
}
