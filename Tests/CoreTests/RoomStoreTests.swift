import XCTest
@testable import RoomTwinCore

final class RoomStoreTests: XCTestCase {
    private func withStore(_ body: (RoomStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(RoomStore(root: root))
    }
    func testSaveReopenAndExport() throws {
        try withStore { store in
            XCTAssertEqual(try store.list(), [])
            let element = RoomElement(id: UUID(), kind: "Wall", width: 4, height: 3, depth: 0)
            let room = try store.save(name: " Living room ", elements: [element], capturedJSON: Data("{}".utf8)) {
                try Data("model".utf8).write(to: $0)
            }
            XCTAssertEqual(room.name, "Living room")
            XCTAssertEqual(try RoomStore(root: store.root).list(), [room])
            let urls = try store.exportURLs(for: room)
            XCTAssertEqual(urls.count, 3)
            XCTAssertEqual(try Data(contentsOf: urls[1]), Data("{}".utf8))
            try FileManager.default.removeItem(at: urls[0])
            XCTAssertThrowsError(try store.exportURLs(for: room))
        }
    }
    func testFailedExportDoesNotLeavePartialScan() throws {
        try withStore { store in
            XCTAssertThrowsError(try store.save(name: "Room", elements: [], capturedJSON: Data()) { _ in throw StorageError.missingFile("test") })
            XCTAssertEqual(try store.list(), [])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.path), [])
        }
    }
    func testRejectsBlankNameAndMissingModel() throws {
        try withStore { store in
            XCTAssertThrowsError(try store.save(name: " \n ", elements: [], capturedJSON: Data()) { _ in XCTFail("Must validate before export") })
            XCTAssertThrowsError(try store.save(name: "Room", elements: [], capturedJSON: Data()) { _ in })
            XCTAssertEqual(try store.list(), [])
        }
    }
    func testNamesCannotEscapeStorageDirectory() throws {
        try withStore { store in
            let room = try store.save(name: "../../outside", elements: [], capturedJSON: Data()) { try Data([1]).write(to: $0) }
            XCTAssertEqual(store.directory(for: room).deletingLastPathComponent().path, store.root.path)
            XCTAssertEqual(try store.list().count, 1)
        }
    }
}
