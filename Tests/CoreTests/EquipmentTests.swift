import XCTest
@testable import RoomTwinCore

final class EquipmentTests: XCTestCase {
    func testEquipmentPersistsAcrossReopenAndIsScopedToRoom() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("equipment.sqlite")
        let store = try EquipmentStore(url: url)
        let room = UUID()
        var device = Equipment(roomID: room, name: "AC", kind: .airConditioner, position: .init(x: 1, y: 2, z: -1))
        try await store.save(device)
        device.name = "AC updated"; device.position.x = 2
        try await store.save(device)
        let reopened = try EquipmentStore(url: url)
        let devices = try await reopened.devices(roomID: room)
        XCTAssertEqual(devices, [device])
        let other = try await reopened.devices(roomID: UUID())
        XCTAssertTrue(other.isEmpty)
    }
    func testReadingCacheDeduplicatesAndDeleteCascades() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EquipmentStore(url: root.appendingPathComponent("equipment.sqlite"))
        let device = Equipment(roomID: UUID(), name: "Sensor", position: .init(x: 0, y: 1, z: 0))
        try await store.save(device)
        let reading = TelemetryReading(id: "event-1", deviceID: device.id, metric: "temperature", value: 23, unit: "°C", timestamp: 12345, source: "simulated")
        try await store.cache([reading, reading], for: device.id)
        let cached = try await store.readings(deviceID: device.id)
        XCTAssertEqual(cached, [reading])
        try await store.delete(id: device.id)
        let after = try await store.readings(deviceID: device.id)
        XCTAssertTrue(after.isEmpty)
    }
    func testReadingsCannotCrossDevices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EquipmentStore(url: root.appendingPathComponent("equipment.sqlite"))
        let a = Equipment(roomID: UUID(), name: "Sensor", position: .init(x: 0, y: 0, z: 0))
        try await store.save(a)
        let reading = TelemetryReading(id: "wrong-device", deviceID: UUID(), metric: "power", value: 1, unit: "W", timestamp: 1, source: "mqtt")
        do { try await store.cache([reading], for: a.id); XCTFail("Must reject another device's readings") } catch {}
        let values = try await store.readings(deviceID: a.id)
        XCTAssertTrue(values.isEmpty)
    }
    func testEquipmentValidation() throws {
        var device = Equipment(roomID: UUID(), name: "Sensor", position: .init(x: 0, y: 0, z: 0), topic: "room/+/temperature")
        XCTAssertThrowsError(try device.validated())
        device.topic = "room/sensor1"
        XCTAssertNoThrow(try device.validated())
        device.position.y = .nan
        XCTAssertThrowsError(try device.validated())
        device.position.y = 1; device.name = "  "
        XCTAssertThrowsError(try device.validated())
    }
    func testLegacyEquipmentAndSurfaceNormalRoundTrip() throws {
        var device = Equipment(roomID: UUID(), name: "AC", kind: .airConditioner, position: .init(x: 1, y: 2, z: 0))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(device)) as! [String: Any]
        json.removeValue(forKey: "surfaceNormal")
        let old = try JSONDecoder().decode(Equipment.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.surfaceNormal)
        device.surfaceNormal = .init(x: 0, y: 0, z: 1)
        XCTAssertEqual(try JSONDecoder().decode(Equipment.self, from: JSONEncoder().encode(device)), device)
    }
    func testTelemetryEndpointValidation() throws {
        XCTAssertThrowsError(try TelemetryClient(endpoint: "file:///tmp", token: "token"))
        XCTAssertThrowsError(try TelemetryClient(endpoint: "http://collector.local:8080", token: ""))
        XCTAssertThrowsError(try TelemetryClient(endpoint: "http://external.example.com", token: "token"))
        XCTAssertNoThrow(try TelemetryClient(endpoint: "http://collector.local:8080", token: "token"))
        XCTAssertNoThrow(try TelemetryClient(endpoint: "https://collector.example.com", token: "token"))
    }
}
