import SceneKit
import SwiftUI
import UIKit

/// One part on its own, on white, like a product photo (2026-11-26). The part is the detailed model from
/// Resources/DORME_robot.usdz (cad/export_app_model.py + cad/app_model/), so the "photo" is a render of the same
/// model the home page shows: real colours and layouts from the makers' drawings, not a vendor photograph.
enum PartStudio {
    /// All scene work happens on this queue: list thumbnails render here so typing in search never waits for them.
    private static let queue = DispatchQueue(label: "dorme.partstudio", qos: .userInitiated)
    /// The model, loaded once and only read from (parts are cloned out of it).
    nonisolated(unsafe) private static let template: SCNScene? = {
        guard let url = Bundle.main.url(forResource: "DORME_robot", withExtension: "usdz") else { return nil }
        return try? SCNScene(url: url, options: nil)
    }()
    nonisolated(unsafe) private static var thumbs: [String: UIImage] = [:]
    static let environment: UIImage = studioEnvironment()

    /// A soft studio: bright overhead softbox, light-grey walls, darker floor (equirectangular, 256 x 128).
    static func studioEnvironment() -> UIImage {
        let w = 256.0, h = 128.0
        return FaceRenderer.rgba8(size: CGSize(width: w, height: h), scale: 1) { g in
            let colors = [UIColor(white: 1.0, alpha: 1).cgColor, UIColor(white: 0.82, alpha: 1).cgColor,
                          UIColor(white: 0.62, alpha: 1).cgColor, UIColor(white: 0.30, alpha: 1).cgColor] as CFArray
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.35, 0.52, 1])!
            g.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: h), options: [])
            UIColor(white: 1, alpha: 0.9).setFill()                    // two softboxes
            g.fillEllipse(in: CGRect(x: w * 0.10, y: h * 0.08, width: w * 0.22, height: h * 0.16))
            g.fillEllipse(in: CGRect(x: w * 0.60, y: h * 0.12, width: w * 0.16, height: h * 0.12))
        }
    }

    /// A copy of one part, centred on the origin, materials set up like the main view.
    private static func part(_ nodeName: String) -> (node: SCNNode, radius: Float)? {
        guard let src = template?.rootNode.childNode(withName: nodeName, recursively: true) else { return nil }
        let copy = src.clone()
        copy.transform = src.worldTransform
        copy.enumerateHierarchy { n, _ in
            guard let geo = n.geometry?.copy() as? SCNGeometry else { return }
            geo.materials = geo.materials.map { m in
                let c = (m.copy() as? SCNMaterial) ?? m
                if c.lightingModel != .constant { c.lightingModel = .physicallyBased }
                if (c.name ?? "").lowercased().contains("led_ring") {
                    c.emission.contents = UIColor(red: 1, green: 0.78, blue: 0.16, alpha: 1)
                    c.emission.intensity = 0.9
                }
                if n.name == "LCD_screen" { c.diffuse.contents = UIColor.black; c.lightingModel = .constant }
                return c
            }
            n.geometry = geo
        }
        let holder = SCNNode()
        holder.addChildNode(copy)
        let (lo, hi) = holder.boundingBox
        let c = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
        copy.position = SCNVector3(copy.position.x - c.x, copy.position.y - c.y, copy.position.z - c.z)
        let r = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z) / 2
        return (holder, max(r, 0.004))
    }

    /// A white studio scene with the part, a camera at a three-quarter view and a soft floor shadow.
    static func scene(for nodeName: String, spin: Bool) -> (SCNScene, SCNNode)? {
        queue.sync { makeScene(nodeName, spin: spin) }
    }

    private static func makeScene(_ nodeName: String, spin: Bool) -> (SCNScene, SCNNode)? {
        guard let (part, r) = part(nodeName) else { return nil }
        let scene = SCNScene()
        scene.background.contents = UIColor.white
        scene.lightingEnvironment.contents = environment
        scene.lightingEnvironment.intensity = 0.95
        let turn = SCNNode()
        turn.addChildNode(part)
        scene.rootNode.addChildNode(turn)
        if spin {
            turn.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 24)))
        }
        let (lo, _) = part.boundingBox
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 700
        key.light?.castsShadow = true
        key.light?.shadowMode = .deferred
        key.light?.shadowSampleCount = 16
        key.light?.shadowRadius = 8
        key.light?.shadowColor = UIColor(white: 0, alpha: 0.22)
        key.light?.automaticallyAdjustsShadowProjection = true
        key.position = SCNVector3(r * 2, r * 5, r * 3)
        key.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(key)
        let floor = SCNFloor()
        floor.reflectivity = 0
        let fm = SCNMaterial()
        fm.lightingModel = .shadowOnly
        floor.materials = [fm]
        let floorNode = SCNNode(geometry: floor)
        floorNode.position = SCNVector3(0, lo.y - r * 0.02, 0)
        scene.rootNode.addChildNode(floorNode)
        let cam = SCNCamera()
        cam.fieldOfView = 26
        cam.zNear = Double(r) * 0.05
        cam.zFar = Double(r) * 60
        cam.wantsHDR = true
        cam.wantsExposureAdaptation = false
        cam.screenSpaceAmbientOcclusionIntensity = 0.6
        let camNode = SCNNode()
        camNode.camera = cam
        let d = r / sin(Float(cam.fieldOfView) / 2 * .pi / 180) * 1.12
        camNode.position = SCNVector3(d * 0.62, d * 0.42, d * 0.66)
        camNode.look(at: SCNVector3(0, -r * 0.05, 0))
        scene.rootNode.addChildNode(camNode)
        return (scene, camNode)
    }

    /// A small cached "product shot" for lists, rendered off the main thread.
    static func thumbnail(_ nodeName: String, pixels: CGFloat) async -> UIImage? {
        await withCheckedContinuation { (done: CheckedContinuation<UIImage?, Never>) in
            queue.async {
                if let t = thumbs[nodeName] { done.resume(returning: t); return }
                guard let (scene, cam) = makeScene(nodeName, spin: false) else { done.resume(returning: nil); return }
                let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
                renderer.scene = scene
                renderer.pointOfView = cam
                renderer.autoenablesDefaultLighting = false
                let img = renderer.snapshot(atTime: 0, with: CGSize(width: pixels, height: pixels), antialiasingMode: .multisampling4X)
                thumbs[nodeName] = img
                done.resume(returning: img)
            }
        }
    }
}

/// The interactive product view on a part's page: white, slowly turning, drag to look around.
struct PartProductView: UIViewRepresentable {
    let nodeName: String

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .white
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.autoenablesDefaultLighting = false
        view.accessibilityLabel = "3D view of the part"
        if let (scene, cam) = PartStudio.scene(for: nodeName, spin: true) {
            view.scene = scene
            view.pointOfView = cam
            view.defaultCameraController.target = SCNVector3Zero
            view.isPlaying = true
        }
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}
}

/// A list thumbnail: the part on white, or a symbol for parts with no shape (Wi-Fi, Bluetooth, remote access).
struct PartThumb: View {
    let part: CatalogPart
    var size: CGFloat = 46
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white)
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(2)
            } else if part.node == nil {
                Image(systemName: symbol).font(.system(size: size * 0.4, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            }
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
        .task(id: part.id) {
            if let node = part.node { image = await PartStudio.thumbnail(node, pixels: 96 * scale) }
        }
    }

    private var symbol: String {
        switch part.id {
        case "WIFI": return "wifi"
        case "BLUETOOTH": return "dot.radiowaves.left.and.right"
        default: return "globe"
        }
    }
}
