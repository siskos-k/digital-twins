import XCTest
@testable import RoomTwinCore

final class DemoTelemetryTests: XCTestCase {
    func testEveryCategoryProducesExplicitlySimulatedDeviceReadings() {
        let date = Date(timeIntervalSince1970: 1792350000)
        for kind in EquipmentKind.allCases {
            let device = Equipment(roomID: UUID(), name: "Demo", kind: kind, position: .init(x: 0, y: 1, z: 0))
            let values = DemoTelemetry.readings(for: device, at: date)
            XCTAssertFalse(values.isEmpty)
            XCTAssertTrue(values.allSatisfy { $0.deviceID == device.id && $0.source == "simulated" && $0.timestamp == date.timeIntervalSince1970 && $0.value.isFinite })
            XCTAssertEqual(Set(values.map(\.id)).count, values.count)
        }
    }
    func testDemoHistoryPersistsWithoutAnyNetworkService() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("equipment.sqlite")
        let store = try EquipmentStore(url: url)
        let device = Equipment(roomID: UUID(), name: "Room sensor", position: .init(x: 0, y: 1, z: 0))
        try await store.save(device)
        let first = DemoTelemetry.readings(for: device, at: Date(timeIntervalSince1970: 10000))
        let second = DemoTelemetry.readings(for: device, at: Date(timeIntervalSince1970: 10002))
        try await store.cache(first + second, for: device.id)
        let reopened = try EquipmentStore(url: url)
        let readings = try await reopened.readings(deviceID: device.id)
        XCTAssertEqual(readings.count, first.count + second.count)
        XCTAssertEqual(readings.first?.timestamp, 10002)
        XCTAssertTrue(readings.allSatisfy { $0.source == "simulated" })
        XCTAssertNotEqual(first.first?.value, second.first?.value)
    }
}
