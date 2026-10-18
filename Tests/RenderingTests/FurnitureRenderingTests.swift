import XCTest
import RoomPlan
import SceneKit
@testable import DigitalTwins

final class FurnitureRenderingTests: XCTestCase {
    func testEveryDetectedCategoryHasReadableFurniture() throws {
        let provider = try FurnitureCatalog.provider()
        for category in CapturedRoom.Object.Category.allCases {
            let url = try XCTUnwrap(provider.modelFileURL(for: category))
            let scene = try SCNScene(url: url)
            let bounds = scene.rootNode.boundingBox
            XCTAssertGreaterThan(bounds.max.x - bounds.min.x, 0, "\(category)")
            XCTAssertGreaterThan(bounds.max.y - bounds.min.y, 0, "\(category)")
            XCTAssertGreaterThan(bounds.max.z - bounds.min.z, 0, "\(category)")
        }
    }
    func testFurnishedSampleHasDetailedMeshesAndKeepsOriginal() async throws {
        let source = try XCTUnwrap(Bundle.main.url(forResource: "SampleRoom", withExtension: "usdz"))
        let original = try Data(contentsOf: source)
        let json = Data("{\"source\":\"simulated\",\"sampleVersion\":2}".utf8)
        let furnished = try await FurnishedRoomRenderer.shared.model(json: json)
        func vertexCount(_ url: URL) throws -> Int {
            let scene = try SCNScene(url: url)
            var count = 0
            scene.rootNode.enumerateChildNodes { node, _ in count += node.geometry?.sources(for: .vertex).reduce(0) { $0 + $1.vectorCount } ?? 0 }
            return count
        }
        XCTAssertGreaterThan(try vertexCount(furnished), try vertexCount(source))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testLegacySampleExplainsHowToGetFurniture() async {
        do {
            _ = try await FurnishedRoomRenderer.shared.model(json: Data("{\"source\":\"simulated\"}".utf8))
            XCTFail("Legacy samples lack matching furniture metadata")
        } catch { XCTAssertTrue(error.localizedDescription.contains("new sample room")) }
    }
    func testInvalidScanDataDoesNotProduceAReplacement() async {
        do {
            _ = try await FurnishedRoomRenderer.shared.model(json: Data("{}".utf8))
            XCTFail("An invalid room must not be furnished")
        } catch {}
    }
}
