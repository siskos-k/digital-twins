import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CollectorHealth: Codable {
    public let mqttConnected: Bool
    public let lastError: String?
}

public struct TelemetryClient {
    let endpoint: URL
    let token: String
    let session: URLSession
    public init(endpoint: String, token: String, session: URLSession = .shared) throws {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw EquipmentError.invalid("Enter the local collector URL, for example http://your-mac.local:8080.")
        }
        if url.scheme?.lowercased() == "http", let host = url.host?.lowercased(),
           host != "localhost", host != "127.0.0.1", host != "::1", !host.hasSuffix(".local"), host.contains(".") {
            throw EquipmentError.invalid("For HTTP use the collector's .local hostname (e.g. http://your-mac.local:8080), or use HTTPS.")
        }
        guard !token.isEmpty else { throw EquipmentError.invalid("Enter the collector's API token in IoT settings.") }
        self.endpoint = url; self.token = token; self.session = session
    }
    private func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EquipmentError.invalid("Invalid collector response.") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw EquipmentError.invalid("Collector rejected the API token. Check IoT settings.") }
            throw EquipmentError.invalid("Collector request failed (HTTP \(http.statusCode)).")
        }
        return data
    }
    public func register(_ device: Equipment) async throws {
        _ = try await request(path: "devices/\(device.id.uuidString)", method: "PUT", body: JSONEncoder().encode(device.validated()))
    }
    public func delete(id: UUID) async throws { _ = try await request(path: "devices/\(id.uuidString)", method: "DELETE") }
    public func readings(id: UUID) async throws -> [TelemetryReading] {
        try JSONDecoder().decode([TelemetryReading].self, from: await request(path: "devices/\(id.uuidString)/readings"))
    }
    public func health() async throws -> CollectorHealth { try JSONDecoder().decode(CollectorHealth.self, from: await request(path: "health")) }
}
