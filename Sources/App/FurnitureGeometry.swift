import SceneKit
#if os(macOS)
import AppKit
private typealias ModelColor = NSColor
#else
import UIKit
private typealias ModelColor = UIColor
#endif

/// Small representative models for categories outside Apple's sample catalog.
/// Unit bounding volume, centred at the origin; the caller fits it to the scan.
enum FurnitureGeometry {
    static func make(_ category: String) -> SCNNode {
        let root = SCNNode()
        let white = ModelColor(white: 0.94, alpha: 1)
        let dark = ModelColor(white: 0.12, alpha: 1)
        let metal = ModelColor(white: 0.55, alpha: 1)
        let wood = ModelColor(red: 0.43, green: 0.25, blue: 0.13, alpha: 1)
        let blue = ModelColor(red: 0.18, green: 0.40, blue: 0.53, alpha: 1)
        let fabric = ModelColor(red: 0.70, green: 0.76, blue: 0.72, alpha: 1)
        func box(_ w: CGFloat, _ h: CGFloat, _ d: CGFloat, _ x: Float, _ y: Float, _ z: Float, _ color: ModelColor, round: CGFloat = 0.025) {
            let node = SCNNode(geometry: SCNBox(width: w, height: h, length: d, chamferRadius: min(round, min(w, h, d) / 3)))
            node.position = SCNVector3(x, y, z)
            node.geometry?.firstMaterial = material(color)
            root.addChildNode(node)
        }
        func ring(_ radius: CGFloat, _ pipe: CGFloat, _ x: Float, _ y: Float, _ z: Float, _ color: ModelColor) {
            let node = SCNNode(geometry: SCNTorus(ringRadius: radius, pipeRadius: pipe))
            node.position = SCNVector3(x, y, z)
            node.geometry?.firstMaterial = material(color)
            root.addChildNode(node)
        }
        func legs(top: Float = -0.1) {
            for x: Float in [-0.4, 0.4] { for z: Float in [-0.4, 0.4] { box(0.07, CGFloat(top + 0.5), 0.07, x, (top - 0.5) / 2, z, wood) } }
        }
        switch category {
        case "bed":
            box(1, 0.2, 1, 0, -0.3, 0, wood)
            box(0.94, 0.24, 0.88, 0, -0.08, 0.03, white, round: 0.07)
            box(0.95, 0.8, 0.08, 0, 0.1, -0.46, wood)
            box(0.92, 0.06, 0.55, 0, 0.07, 0.18, blue)
            for x: Float in [-0.23, 0.23] { box(0.37, 0.12, 0.21, x, 0.1, -0.24, fabric, round: 0.06) }
            for x: Float in [-0.4, 0.4] { for z: Float in [-0.4, 0.4] { box(0.08, 0.18, 0.08, x, -0.41, z, wood) } }
        case "refrigerator", "storage":
            box(1, 1, 1, 0, 0, 0, white)
            let splits: [Float] = category == "refrigerator" ? [0.14] : [-0.15, 0.15]
            for y in splits { box(0.96, 0.012, 0.015, 0, y, 0.505, metal, round: 0) }
            for y: Float in [-0.08, 0.32] { box(0.035, 0.19, 0.06, 0.32, y, 0.52, metal) }
        case "stove", "oven", "dishwasher", "washerDryer":
            box(1, 1, 1, 0, 0, 0, white)
            box(0.86, 0.12, 0.03, 0, 0.35, 0.51, metal)
            if category == "washerDryer" {
                let door = SCNNode(geometry: SCNCylinder(radius: 0.3, height: 0.04))
                door.eulerAngles.x = .pi / 2; door.position = SCNVector3(0, -0.05, 0.52)
                door.geometry?.firstMaterial = material(dark); root.addChildNode(door)
            } else if category != "dishwasher" {
                box(0.76, 0.55, 0.04, 0, -0.08, 0.51, dark)
            }
            box(0.65, 0.035, 0.06, 0, 0.2, 0.55, metal)
            if category == "stove" {
                for x: Float in [-0.25, 0.25] { for z: Float in [-0.25, 0.25] { ring(0.13, 0.018, x, 0.51, z, dark) } }
            }
        case "sink", "bathtub":
            let h: CGFloat = category == "sink" ? 0.18 : 0.75
            box(1, h, 0.1, 0, 0.5 - Float(h / 2), -0.45, white)
            box(1, h, 0.1, 0, 0.5 - Float(h / 2), 0.45, white)
            box(0.1, h, 0.9, -0.45, 0.5 - Float(h / 2), 0, white)
            box(0.1, h, 0.9, 0.45, 0.5 - Float(h / 2), 0, white)
            box(0.85, 0.08, 0.85, 0, 0.5 - Float(h), 0, white)
            if category == "sink" { box(0.12, 0.7, 0.12, 0, -0.12, 0, white) }
            box(0.035, 0.15, 0.035, 0, 0.55, -0.35, metal)
            box(0.035, 0.035, 0.15, 0, 0.61, -0.28, metal)
        case "toilet":
            box(0.7, 0.65, 0.3, 0, 0.16, -0.34, white)
            box(0.45, 0.5, 0.55, 0, -0.25, 0.12, white, round: 0.12)
            let bowl = SCNNode(geometry: SCNTorus(ringRadius: 0.27, pipeRadius: 0.06))
            bowl.scale.z = 1.3; bowl.position = SCNVector3(0, 0.03, 0.12)
            bowl.geometry?.firstMaterial = material(white); root.addChildNode(bowl)
        case "television", "fireplace":
            box(1, 0.75, 0.1, 0, 0.1, 0, dark)
            box(0.91, 0.64, 0.015, 0, 0.11, 0.06, blue)
            box(0.06, 0.2, 0.08, 0, -0.35, 0, metal)
            box(0.65, 0.06, 0.35, 0, -0.46, 0.05, dark)
        case "stairs":
            for i in 0..<6 { let h = CGFloat(i + 1) / 6; box(1, h, 1.0 / 6, 0, Float(h / 2) - 0.5, Float(i) / 6 - 0.42, wood, round: 0) }
        case "table":
            box(1, 0.12, 1, 0, 0.44, 0, wood); legs(top: 0.38)
        case "chair":
            box(0.9, 0.12, 0.9, 0, -0.05, 0, fabric); legs(top: -0.1)
            box(0.9, 0.5, 0.1, 0, 0.25, -0.4, fabric)
        case "sofa":
            box(1, 0.25, 1, 0, -0.3, 0, fabric)
            box(1, 0.7, 0.16, 0, 0.1, -0.42, fabric)
            for x: Float in [-0.43, 0.43] { box(0.14, 0.5, 1, x, -0.05, 0, fabric) }
            for x: Float in [-0.2, 0.2] { box(0.36, 0.14, 0.7, x, -0.1, 0.05, fabric, round: 0.06) }
        case "ac":
            box(1, 0.35, 0.25, 0, 0, 0, white, round: 0.05)
            for y: Float in [-0.1, -0.06, -0.02] { box(0.85, 0.015, 0.02, 0, y, 0.13, dark, round: 0) }
            box(0.05, 0.02, 0.02, 0.35, 0.08, 0.13, blue)
        case "light":
            let shade = SCNNode(geometry: SCNCone(topRadius: 0.09, bottomRadius: 0.25, height: 0.25))
            shade.geometry?.firstMaterial = material(white); root.addChildNode(shade)
            box(0.035, 0.3, 0.035, 0, 0.26, 0, metal)
        default:
            box(0.2, 0.26, 0.065, 0, 0, 0, white)
            box(0.13, 0.09, 0.015, 0, 0.025, 0.04, blue)
            box(0.03, 0.012, 0.015, 0, -0.07, 0.04, metal)
        }
        return root
    }
    private static func material(_ color: ModelColor) -> SCNMaterial {
        let result = SCNMaterial()
        result.diffuse.contents = color; result.lightingModel = .physicallyBased
        result.roughness.contents = 0.7; result.metalness.contents = 0.05
        return result
    }
}
