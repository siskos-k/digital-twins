import Foundation
import CSQLite

/// Serializes SQLite access from UI refreshes and HTTP responses.
public actor EquipmentStore {
    private var database: OpaquePointer?
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw EquipmentError.database("Could not open equipment database.")
        }
        database = handle
        sqlite3_busy_timeout(handle, 3000)
        let sql = """
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, room_id TEXT NOT NULL, json BLOB NOT NULL);
        CREATE INDEX IF NOT EXISTS devices_room ON devices(room_id);
        CREATE TABLE IF NOT EXISTS readings (
            id TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
            timestamp REAL NOT NULL, json BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS readings_device ON readings(device_id, timestamp DESC);
        """
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle)); sqlite3_close(handle); database = nil
            throw EquipmentError.database(message)
        }
    }
    deinit { sqlite3_close(database) }
    private func statement(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw failure() }
        for (index, value) in values.enumerated() {
            let status = value.withCString { sqlite3_bind_text(prepared, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard status == SQLITE_OK else { sqlite3_finalize(prepared); throw failure() }
        }
        return prepared
    }
    private func failure() -> EquipmentError { .database(String(cString: sqlite3_errmsg(database))) }
    private func execute(_ sql: String, _ values: [String] = []) throws {
        let prepared = try statement(sql, values); defer { sqlite3_finalize(prepared) }
        guard sqlite3_step(prepared) == SQLITE_DONE else { throw failure() }
    }
    private func query<T: Decodable>(_ sql: String, _ values: [String]) throws -> [T] {
        let prepared = try statement(sql, values); defer { sqlite3_finalize(prepared) }
        var result: [T] = []
        while true {
            let status = sqlite3_step(prepared)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_text(prepared, 0) else { throw failure() }
            let data = Data(String(cString: bytes).utf8)
            result.append(try JSONDecoder().decode(T.self, from: data))
        }
    }
    private func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    public func devices(roomID: UUID) throws -> [Equipment] {
        try query("SELECT json FROM devices WHERE room_id=? ORDER BY id", [roomID.uuidString])
    }
    public func save(_ device: Equipment) throws {
        let value = try device.validated()
        try execute("INSERT INTO devices(id,room_id,json) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET room_id=excluded.room_id,json=excluded.json", [value.id.uuidString, value.roomID.uuidString, try json(value)])
    }
    public func delete(id: UUID) throws { try execute("DELETE FROM devices WHERE id=?", [id.uuidString]) }
    public func cache(_ readings: [TelemetryReading], for deviceID: UUID) throws {
        guard readings.allSatisfy({ $0.deviceID == deviceID && $0.value.isFinite && $0.timestamp.isFinite }) else { throw EquipmentError.invalid("Invalid device readings.") }
        try execute("BEGIN IMMEDIATE")
        do {
            for reading in readings {
                try execute("INSERT OR IGNORE INTO readings(id,device_id,timestamp,json) VALUES(?,?,?,?)", [reading.id, deviceID.uuidString, String(reading.timestamp), try json(reading)])
            }
            try execute("DELETE FROM readings WHERE device_id=? AND id NOT IN (SELECT id FROM readings WHERE device_id=? ORDER BY timestamp DESC LIMIT 2000)", [deviceID.uuidString, deviceID.uuidString])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func readings(deviceID: UUID) throws -> [TelemetryReading] {
        try query("SELECT json FROM readings WHERE device_id=? ORDER BY timestamp DESC LIMIT 500", [deviceID.uuidString])
    }
}
