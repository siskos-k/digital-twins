import XCTest
@testable import RoomTwinCore

private final class CollectorProtocol: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.respond!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class TelemetryClientTests: XCTestCase {
    private func client() throws -> TelemetryClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CollectorProtocol.self]
        return try TelemetryClient(endpoint: "http://collector.local:8080", token: "test-token", session: URLSession(configuration: configuration))
    }
    func testRegisterAndDecodeCollectorReadings() async throws {
        let device = Equipment(roomID: UUID(), name: "Sensor", position: .init(x: 1, y: 1, z: 1), topic: "room1/sensor1")
        CollectorProtocol.respond = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/devices/\(device.id.uuidString)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return (200, Data("{\"saved\":true}".utf8))
        }
        let client = try client()
        try await client.register(device)
        let reading = TelemetryReading(id: "reading-1", deviceID: device.id, metric: "temperature", value: 24.3, unit: "°C", timestamp: 1792350000, source: "simulated")
        CollectorProtocol.respond = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/devices/\(device.id.uuidString)/readings")
            return (200, try JSONEncoder().encode([reading]))
        }
        let readings = try await client.readings(id: device.id)
        XCTAssertEqual(readings, [reading])
    }
    func testAuthenticationFailureIsActionable() async throws {
        CollectorProtocol.respond = { _ in (401, Data("{\"error\":\"Invalid API token\"}".utf8)) }
        do { _ = try await client().health(); XCTFail("Must fail on invalid token") }
        catch { XCTAssertTrue(error.localizedDescription.contains("API token")) }
    }
}
