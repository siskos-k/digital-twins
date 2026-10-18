import Foundation

public struct RoomPosition: Codable, Equatable {
    public var x: Float
    public var y: Float
    public var z: Float
    public init(x: Float, y: Float, z: Float) { self.x = x; self.y = y; self.z = z }
}

public enum EquipmentKind: String, CaseIterable, Codable, Identifiable {
    case airConditioner = "AC / heat pump"
    case environment = "Temperature / humidity sensor"
    case power = "Energy meter"
    case light = "Light"
    case occupancy = "Occupancy sensor"
    case airQuality = "Air quality sensor"
    case contact = "Door / window sensor"
    case thermostat = "Thermostat / radiator"
    case other = "Other"
    public var id: String { rawValue }
    public var symbol: String {
        switch self {
        case .airConditioner: return "air.conditioner.horizontal"
        case .environment: return "thermometer.medium"
        case .power: return "bolt.fill"
        case .light: return "lightbulb"
        case .occupancy: return "person.fill"
        case .airQuality: return "aqi.medium"
        case .contact: return "door.left.hand.open"
        case .thermostat: return "thermostat"
        case .other: return "sensor"
        }
    }
}

public struct Equipment: Codable, Identifiable, Equatable {
    public let id: UUID
    public let roomID: UUID
    public var name: String
    public var kind: EquipmentKind
    public var position: RoomPosition
    public var manufacturer: String
    public var model: String
    public var notes: String
    public var topic: String
    public var collectorEndpoint: String?
    public init(id: UUID = UUID(), roomID: UUID, name: String = "", kind: EquipmentKind = .environment,
                position: RoomPosition, manufacturer: String = "", model: String = "", notes: String = "", topic: String = "") {
        self.id = id; self.roomID = roomID; self.name = name; self.kind = kind; self.position = position
        self.manufacturer = manufacturer; self.model = model; self.notes = notes; self.topic = topic
    }
    public func validated() throws -> Equipment {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty else { throw EquipmentError.invalid("Enter an equipment name.") }
        guard [position.x, position.y, position.z].allSatisfy({ $0.isFinite }) else { throw EquipmentError.invalid("Equipment position is invalid.") }
        guard !result.topic.contains("#"), !result.topic.contains("+"), !result.topic.contains("\0"), result.topic.utf8.count <= 512 else {
            throw EquipmentError.invalid("Use one exact MQTT topic without wildcards (maximum 512 bytes).")
        }
        return result
    }
}

public enum EquipmentError: LocalizedError {
    case invalid(String), database(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message), .database(let message): return message }
    }
}

public struct TelemetryReading: Codable, Identifiable, Equatable {
    public let id: String
    public let deviceID: UUID
    public let metric: String
    public let value: Double
    public let unit: String
    public let timestamp: Double
    public let source: String
    public var date: Date { Date(timeIntervalSince1970: timestamp) }
    public init(id: String, deviceID: UUID, metric: String, value: Double, unit: String, timestamp: Double, source: String) {
        self.id = id; self.deviceID = deviceID; self.metric = metric; self.value = value; self.unit = unit
        self.timestamp = timestamp; self.source = source
    }
}
