import Foundation

/// Deterministic, smoothly changing demonstration data. Never represents a physical sensor.
public enum DemoTelemetry {
    public static func readings(for device: Equipment, at date: Date = Date()) -> [TelemetryReading] {
        let wave = sin(date.timeIntervalSince1970 / 15)
        let temperature = 23.5 + 0.8 * wave
        let values: [(String, Double, String)]
        switch device.kind {
        case .airConditioner:
            values = [("temperature", temperature, "°C"), ("targetTemperature", 22, "°C"), ("power", 650 + 100 * wave, "W"), ("on", 1, "")]
        case .environment:
            values = [("temperature", temperature, "°C"), ("humidity", 48 + 5 * wave, "%")]
        case .power:
            values = [("power", 250 + 50 * wave, "W")]
        case .light:
            values = [("brightness", 70 + 10 * wave, "%"), ("power", 8 + wave, "W"), ("on", 1, "")]
        case .occupancy:
            values = [("occupied", wave >= 0 ? 1 : 0, "")]
        case .airQuality:
            values = [("co2", 650 + 100 * wave, "ppm"), ("temperature", temperature, "°C")]
        case .contact:
            values = [("open", wave >= 0 ? 1 : 0, "")]
        case .thermostat:
            values = [("temperature", temperature, "°C"), ("targetTemperature", 22, "°C")]
        case .other:
            values = [("temperature", temperature, "°C")]
        }
        return values.map { metric, value, unit in
            TelemetryReading(id: UUID().uuidString, deviceID: device.id, metric: metric, value: value, unit: unit,
                             timestamp: date.timeIntervalSince1970, source: "simulated")
        }
    }
}
