import Foundation

public struct RoomElement: Codable, Identifiable, Equatable {
    public let id: UUID
    public let kind: String
    public let width: Float
    public let height: Float
    public let depth: Float
    public init(id: UUID, kind: String, width: Float, height: Float, depth: Float) {
        self.id = id; self.kind = kind; self.width = width; self.height = height; self.depth = depth
    }
}

public struct SavedRoom: Codable, Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let createdAt: Date
    public let elements: [RoomElement]
    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), elements: [RoomElement]) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.elements = elements
    }
}

public enum StorageError: LocalizedError {
    case emptyName, missingFile(String)
    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Give this room a name before saving."
        case .missingFile(let name): return "The saved room is missing \(name)."
        }
    }
}

/// Each room is committed by renaming a complete staging directory.
/// Incomplete saves never appear in the library. Names are metadata, never paths.
public struct RoomStore {
    public let root: URL
    private let files = FileManager.default
    public init(root: URL) { self.root = root }
    public func directory(for room: SavedRoom) -> URL { root.appendingPathComponent(room.id.uuidString, isDirectory: true) }
    public func modelURL(for room: SavedRoom) -> URL { directory(for: room).appendingPathComponent("model.usdz") }
    public func list() throws -> [SavedRoom] {
        guard files.fileExists(atPath: root.path) else { return [] }
        return try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .map { try JSONDecoder().decode(SavedRoom.self, from: Data(contentsOf: $0.appendingPathComponent("metadata.json"))) }
            .sorted { $0.createdAt > $1.createdAt }
    }
    public func save(name: String, elements: [RoomElement], capturedJSON: Data, exportModel: (URL) throws -> Void) throws -> SavedRoom {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw StorageError.emptyName }
        let room = SavedRoom(name: cleanName, elements: elements)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".staging-\(room.id.uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        try exportModel(staging.appendingPathComponent("model.usdz"))
        let model = staging.appendingPathComponent("model.usdz")
        guard files.fileExists(atPath: model.path), (try Data(contentsOf: model)).count > 0 else { throw StorageError.missingFile("model.usdz") }
        try capturedJSON.write(to: staging.appendingPathComponent("room.json"), options: .atomic)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(room).write(to: staging.appendingPathComponent("metadata.json"), options: .atomic)
        try files.moveItem(at: staging, to: directory(for: room))
        return room
    }
    public func exportURLs(for room: SavedRoom) throws -> [URL] {
        let urls = [modelURL(for: room), directory(for: room).appendingPathComponent("room.json"), directory(for: room).appendingPathComponent("metadata.json")]
        for url in urls {
            guard files.isReadableFile(atPath: url.path) else { throw StorageError.missingFile(url.lastPathComponent) }
        }
        return urls
    }
}
