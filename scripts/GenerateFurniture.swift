import Foundation
import SceneKit
import AppKit

/// Run with: swiftc Sources/App/FurnitureGeometry.swift scripts/GenerateFurniture.swift -o /tmp/generate-furniture
@main
struct GenerateFurniture {
    static func main() throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let generated = base.appendingPathComponent("Resources/Furniture.bundle/Generated", isDirectory: true)
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        for kind in ["bed", "refrigerator", "storage", "stove", "oven", "dishwasher", "washerDryer", "sink", "bathtub", "toilet", "television", "fireplace", "stairs", "table", "chair", "sofa"] {
            let scene = SCNScene(); scene.rootNode.addChildNode(FurnitureGeometry.make(kind))
            guard scene.write(to: generated.appendingPathComponent(kind + ".usdc"), options: nil, delegate: nil, progressHandler: nil) else {
                throw NSError(domain: "FurnitureExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not export \(kind)"])
            }
        }
        let sourceURL = base.appendingPathComponent("Resources/SampleRoom.usdz")
        let scene = SCNScene()
        func structure(_ name: String, _ w: CGFloat, _ h: CGFloat, _ d: CGFloat, _ x: Float, _ y: Float, _ z: Float, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
            let node = SCNNode(geometry: SCNBox(width: w, height: h, length: d, chamferRadius: 0))
            node.name = name; node.position = SCNVector3(x, y, z)
            node.geometry?.firstMaterial?.diffuse.contents = NSColor(red: r, green: g, blue: b, alpha: 1)
            scene.rootNode.addChildNode(node)
        }
        structure("floor", 5, 0.05, 4, 0, -0.025, 0, 0.25, 0.32, 0.38)
        structure("back", 5, 2.8, 0.1, 0, 1.4, -2, 0.88, 0.92, 0.96)
        structure("left", 0.1, 2.8, 4, -2.5, 1.4, 0, 0.65, 0.78, 0.88)
        structure("right", 0.1, 2.8, 4, 2.5, 1.4, 0, 0.88, 0.84, 0.74)
        structure("window", 1.8, 1.2, 0.03, 0, 1.5, -1.93, 0.1, 0.4, 0.65)
        let specifications: [(String, String, SCNVector3, SCNVector3, CGFloat)] = [
            ("table", "Table/Default/DefaultTable.rooms.usdc", SCNVector3(1.2, 0.75, 0.7), SCNVector3(1.3, 0.375, -0.8), 0),
            ("sample-sofa", "Sofa/Default/Rectangular.rooms.usdc", SCNVector3(1.7, 0.9, 0.85), SCNVector3(-1.7, 0.45, 0.4), -.pi / 2),
            ("sample-chair", "Chair/Default/DefaultChair.rooms.usdc", SCNVector3(0.6, 1, 0.6), SCNVector3(1.3, 0.5, 0.2), 0)
        ]
        let furnished = SCNScene()
        for child in scene.rootNode.childNodes { furnished.rootNode.addChildNode(child.clone()) }
        for (name, path, size, centre, angle) in specifications {
            let box = SCNNode(geometry: SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0))
            box.name = name; box.position = centre; box.eulerAngles.y = angle
            scene.rootNode.addChildNode(box)
            let asset = try SCNScene(url: base.appendingPathComponent("Resources/Furniture.bundle/AppleCatalog/Resources/" + path))
            let model = SCNNode()
            for child in asset.rootNode.childNodes { model.addChildNode(child.clone()) }
            model.enumerateChildNodes { node, _ in
                for material in node.geometry?.materials ?? [] {
                    material.diffuse.contents = name == "sample-sofa" ? NSColor(red: 0.25, green: 0.43, blue: 0.38, alpha: 1) : name == "table" ? NSColor(red: 0.5, green: 0.3, blue: 0.15, alpha: 1) : NSColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1)
                }
            }
            let bounds = model.boundingBox
            let nativeSize = SCNVector3(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z)
            let offset = SCNNode(); offset.position = SCNVector3(-(bounds.max.x + bounds.min.x) / 2, -(bounds.max.y + bounds.min.y) / 2, -(bounds.max.z + bounds.min.z) / 2)
            offset.addChildNode(model)
            let scaled = SCNNode(); scaled.scale = SCNVector3(size.x / nativeSize.x, size.y / nativeSize.y, size.z / nativeSize.z)
            scaled.addChildNode(offset)
            let placement = SCNNode(); placement.position = centre; placement.eulerAngles.y = angle; placement.addChildNode(scaled)
            furnished.rootNode.addChildNode(placement)
        }
        guard scene.write(to: sourceURL, options: nil, delegate: nil, progressHandler: nil),
              furnished.write(to: base.appendingPathComponent("Resources/SampleRoomFurnished.usdz"), options: nil, delegate: nil, progressHandler: nil) else {
            throw NSError(domain: "SampleExport", code: 1)
        }
        print("Generated 16 fallback models and matching furnished / scan samples")
    }
}
