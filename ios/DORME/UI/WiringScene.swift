import SceneKit
import UIKit

/// The exploded wiring as SceneKit nodes (2026-11-26): every conductor from Resources/robot_wiring.json as a round
/// tube in its own insulation colour and gauge, with what is at each end: a solder fillet, a screw-terminal ferrule, a
/// ring terminal, a plug body, a heat-shrink splice sleeve or a Dupont housing. Each wire also gets an invisible, fatter
/// copy so a finger can hit it. Plug halves that mate across the tray / chassis / cover split are joined by a dotted line.
@MainActor
enum WiringScene {
    static let rootName = "_wiring"

    static func build(_ wiring: Wiring) -> SCNNode {
        let root = SCNNode()
        root.name = rootName
        for w in wiring.wires {
            let pts = w.points.map { SCNVector3(Float($0[0]), Float($0[1]), Float($0[2])) }
            guard pts.count >= 2 else { continue }
            let node = SCNNode()
            node.name = "wire:" + w.id
            let color = UIColor(red: w.color[0], green: w.color[1], blue: w.color[2], alpha: 1)
            let r = Float(max(0.0006, w.d / 2))
            let tube = SCNNode(geometry: tubeGeometry(pts, radius: r, sides: w.kind == "usb" ? 10 : 7,
                                                      material: insulation(color, glossy: w.kind == "usb")))
            tube.name = "wire:" + w.id
            node.addChildNode(tube)
            let hit = SCNNode(geometry: tubeGeometry(pts, radius: max(r * 2.2, 0.0035), sides: 5, material: invisible()))
            hit.name = "wire:" + w.id
            node.addChildNode(hit)
            let tA = direction(pts[0], pts[min(1, pts.count - 1)])
            let tB = direction(pts[pts.count - 1], pts[max(pts.count - 2, 0)])
            node.addChildNode(endFitting(w.from.joint, at: pts[0], toward: tA, wire: w, radius: r))
            node.addChildNode(endFitting(w.to.joint, at: pts[pts.count - 1], toward: tB, wire: w, radius: r))
            root.addChildNode(node)
        }
        for pair in wiring.mates where pair.count == 2 {
            let a = SCNVector3(Float(pair[0][0]), Float(pair[0][1]), Float(pair[0][2]))
            let b = SCNVector3(Float(pair[1][0]), Float(pair[1][1]), Float(pair[1][2]))
            root.addChildNode(dotted(a, b))
        }
        return root
    }

    // MARK: Materials

    private static func insulation(_ c: UIColor, glossy: Bool) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = c
        m.roughness.contents = glossy ? 0.35 : 0.5        // PVC / silicone insulation
        m.metalness.contents = 0.0
        return m
    }

    private static func metal(_ c: UIColor, rough: CGFloat = 0.3) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = c
        m.roughness.contents = rough
        m.metalness.contents = 1.0
        return m
    }

    private static func invisible() -> SCNMaterial {
        let m = SCNMaterial()
        m.colorBufferWriteMask = []
        m.writesToDepthBuffer = false
        return m
    }

    static let solder = UIColor(red: 0.78, green: 0.79, blue: 0.80, alpha: 1)
    static let brass = UIColor(red: 0.80, green: 0.66, blue: 0.36, alpha: 1)

    // MARK: Ends

    private static func endFitting(_ joint: String, at p: SCNVector3, toward t: SCNVector3, wire w: Wiring.Wire, radius r: Float) -> SCNNode {
        let n: SCNNode
        switch joint {
        case "solder":
            let s = SCNSphere(radius: CGFloat(r * 1.55))
            s.segmentCount = 12
            s.materials = [metal(solder, rough: 0.22)]
            n = SCNNode(geometry: s)
        case "screw":
            let c = SCNCylinder(radius: CGFloat(r * 1.25), height: 0.006)       // bootlace ferrule
            c.radialSegmentCount = 12
            c.materials = [metal(solder, rough: 0.35)]
            n = SCNNode(geometry: c)
            orient(n, along: t, offset: 0.003)
        case "ring":
            let tor = SCNTorus(ringRadius: 0.0028, pipeRadius: 0.0007)
            tor.ringSegmentCount = 16
            tor.pipeSegmentCount = 8
            tor.materials = [metal(brass, rough: 0.3)]
            n = SCNNode(geometry: tor)
        case "plug":
            let big = w.awg == "16" || w.awg == "18"
            let b = SCNBox(width: big ? 0.006 : 0.004, height: big ? 0.006 : 0.004, length: big ? 0.012 : 0.007,
                           chamferRadius: 0.0006)
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = big ? UIColor(red: 0.93, green: 0.90, blue: 0.78, alpha: 1)      // Tamiya nylon
                                     : UIColor(red: 0.95, green: 0.94, blue: 0.90, alpha: 1)      // JST PH
            m.roughness.contents = 0.55
            b.materials = [m]
            n = SCNNode(geometry: b)
            orientBox(n, along: t, offset: big ? 0.004 : 0.0025)
        case "splice":
            let c = SCNCylinder(radius: CGFloat(r * 1.7), height: 0.012)       // heat-shrink sleeve
            c.radialSegmentCount = 12
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = UIColor(white: 0.07, alpha: 1)
            m.roughness.contents = 0.6
            c.materials = [m]
            n = SCNNode(geometry: c)
            orient(n, along: t, offset: 0.005)
        case "dupont":
            let b = SCNBox(width: 0.0026, height: 0.0026, length: 0.014, chamferRadius: 0.0002)
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = UIColor(white: 0.06, alpha: 1)
            m.roughness.contents = 0.5
            b.materials = [m]
            n = SCNNode(geometry: b)
            orientBox(n, along: t, offset: 0.006)
        default:
            let s = SCNSphere(radius: CGFloat(r * 1.3))
            s.materials = [metal(solder)]
            n = SCNNode(geometry: s)
        }
        n.position = joint == "screw" || joint == "splice" || joint == "plug" || joint == "dupont" ? n.position + p : p
        n.name = "wire:" + w.id
        return n
    }

    /// Cylinders run along their local Y: turn Y onto `t` and move the centre `offset` along it.
    private static func orient(_ n: SCNNode, along t: SCNVector3, offset: Float) {
        n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(SIMD3(t.x, t.y, t.z)))
        n.position = SCNVector3(t.x * offset, t.y * offset, t.z * offset)
    }

    /// Boxes are long along their local Z.
    private static func orientBox(_ n: SCNNode, along t: SCNVector3, offset: Float) {
        n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: simd_normalize(SIMD3(t.x, t.y, t.z)))
        n.position = SCNVector3(t.x * offset, t.y * offset, t.z * offset)
    }

    private static func direction(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        let d = SIMD3<Float>(b.x - a.x, b.y - a.y, b.z - a.z)
        let l = simd_length(d)
        return l > 1e-6 ? SCNVector3(d.x / l, d.y / l, d.z / l) : SCNVector3(0, 1, 0)
    }

    private static func dotted(_ a: SCNVector3, _ b: SCNVector3) -> SCNNode {
        let root = SCNNode()
        let d = SIMD3<Float>(b.x - a.x, b.y - a.y, b.z - a.z)
        let L = simd_length(d)
        let count = max(2, Int(L / 0.006))
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor(white: 0.55, alpha: 1)
        for i in 0...count {
            let t = Float(i) / Float(count)
            let s = SCNSphere(radius: 0.0007)
            s.segmentCount = 6
            s.materials = [m]
            let n = SCNNode(geometry: s)
            n.position = SCNVector3(a.x + d.x * t, a.y + d.y * t, a.z + d.z * t)
            root.addChildNode(n)
        }
        return root
    }

    // MARK: Tube

    /// A round tube along `pts` (parallel-transport frames, so it never twists), with end caps.
    static func tubeGeometry(_ pts: [SCNVector3], radius r: Float, sides: Int, material: SCNMaterial) -> SCNGeometry {
        let p = pts.map { SIMD3<Float>($0.x, $0.y, $0.z) }
        var tangents: [SIMD3<Float>] = []
        for i in 0..<p.count {
            let a = p[max(0, i - 1)], b = p[min(p.count - 1, i + 1)]
            let t = b - a
            tangents.append(simd_length(t) > 1e-7 ? simd_normalize(t) : SIMD3(0, 1, 0))
        }
        var normal = simd_cross(tangents[0], abs(tangents[0].y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0))
        normal = simd_normalize(normal)
        var verts: [SCNVector3] = [], norms: [SCNVector3] = [], idx: [Int32] = []
        for i in 0..<p.count {
            if i > 0 {
                // rotate the previous normal by the turn between tangents
                let axis = simd_cross(tangents[i - 1], tangents[i])
                let s = simd_length(axis)
                if s > 1e-6 {
                    let ang = atan2(s, simd_dot(tangents[i - 1], tangents[i]))
                    normal = simd_act(simd_quatf(angle: ang, axis: axis / s), normal)
                }
            }
            let binormal = simd_normalize(simd_cross(tangents[i], normal))
            for k in 0..<sides {
                let a = Float(k) / Float(sides) * 2 * .pi
                let dir = normal * cos(a) + binormal * sin(a)
                let v = p[i] + dir * r
                verts.append(SCNVector3(v.x, v.y, v.z))
                norms.append(SCNVector3(dir.x, dir.y, dir.z))
            }
        }
        let rings = p.count
        for i in 0..<(rings - 1) {
            for k in 0..<sides {
                let a = Int32(i * sides + k), b = Int32(i * sides + (k + 1) % sides)
                let c = Int32((i + 1) * sides + k), d = Int32((i + 1) * sides + (k + 1) % sides)
                idx += [a, b, c, b, d, c]          // outward: (b - a) x (c - a) points away from the axis
            }
        }
        // caps
        for (ring, sign) in [(0, Float(-1)), (rings - 1, Float(1))] {
            let centre = Int32(verts.count)
            let t = tangents[ring] * sign
            verts.append(SCNVector3(p[ring].x, p[ring].y, p[ring].z))
            norms.append(SCNVector3(t.x, t.y, t.z))
            for k in 0..<sides {
                let a = Int32(ring * sides + k), b = Int32(ring * sides + (k + 1) % sides)
                idx += sign > 0 ? [centre, a, b] : [centre, b, a]
            }
        }
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: norms)],
                              elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        geo.materials = [material]
        return geo
    }
}

extension SCNVector3 {
    static func + (a: SCNVector3, b: SCNVector3) -> SCNVector3 { SCNVector3(a.x + b.x, a.y + b.y, a.z + b.z) }
}
