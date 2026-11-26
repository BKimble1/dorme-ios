import SceneKit
import SwiftUI
import DORMEKit

/// The robot's 3D model (Resources/DORME_robot.usdz, generated from the CAD by cad/export_app_model.py).
/// Drag to rotate, pinch to zoom. Tap the cover to open it; tap a part to go to it.
/// The screen shows the robot's live face (FaceRenderer, the same drawing as the LCD).
/// Parts glow red or orange when the robot reports a fault or warning. While a part inside has a problem, or an inside
/// part is selected, the cover turns see-through so the part can be seen.
struct RobotSceneView: UIViewRepresentable {
    /// Part status keyed by PartKey.norm(id).
    var statuses: [String: String] = [:]
    var selected: String?
    /// Cover on (closed robot) or off (inside view).
    var showCover = true
    /// Coordinator face state ("idle", "fault", ...). nil = screen dark (not connected).
    var face: String?
    /// The owner's message while the face state is "note".
    var note: ScreenNote? = nil
    var onTap: ((String) -> Void)?
    var onCoverTap: (() -> Void)?

    /// Parts you can see on the closed robot; anything else is "inside".
    static let outside: Set<String> = ["a03cover", "a01chassis", "a04bezel", "a05hatch", "lcd", "w1", "w2", "w3", "w4",
                                       "sonar", "camera", "s2switch", "jchg"]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.defaultCameraController.minimumVerticalAngle = 3      // never orbit below the floor
        view.defaultCameraController.maximumVerticalAngle = 70
        view.preferredFramesPerSecond = 60
        view.accessibilityLabel = "3D model of DORM-E"
        if let url = Bundle.main.url(forResource: "DORME_robot", withExtension: "usdz"),
           let scene = try? SCNScene(url: url, options: nil) {
            view.scene = scene
            Self.stage(scene, in: view)
            context.coordinator.index(scene.rootNode)
        }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        context.coordinator.startFace()
        return view
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.stopFace()
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply()
    }

    /// Studio look: image-based light for soft reflections, a key light with soft shadows on an invisible floor,
    /// a rim light, ambient occlusion and a touch of bloom so the screen glows.
    private static func stage(_ scene: SCNScene, in view: SCNView) {
        let root = scene.rootNode
        let (minV, maxV) = root.boundingBox
        let center = SCNVector3((minV.x + maxV.x) / 2, (minV.y + maxV.y) / 2, (minV.z + maxV.z) / 2)
        let size = max(maxV.x - minV.x, maxV.y - minV.y, maxV.z - minV.z)

        root.enumerateHierarchy { node, _ in
            for m in node.geometry?.materials ?? [] where m.lightingModel != .constant {
                m.lightingModel = .physicallyBased
            }
        }
        scene.lightingEnvironment.contents = studioEnvironment()
        scene.lightingEnvironment.intensity = 0.75

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 620
        key.light?.color = UIColor(white: 1, alpha: 1)
        key.light?.castsShadow = true
        key.light?.shadowMode = .forward
        key.light?.shadowSampleCount = 16
        key.light?.shadowRadius = 6
        key.light?.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.light?.shadowColor = UIColor(white: 0, alpha: 0.38)
        key.light?.automaticallyAdjustsShadowProjection = true
        key.light?.maximumShadowDistance = Double(size) * 6
        key.position = SCNVector3(center.x + size, center.y + size * 2.2, center.z + size * 1.4)
        key.look(at: center)
        root.addChildNode(key)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .directional
        rim.light?.intensity = 220
        rim.position = SCNVector3(center.x - size * 1.5, center.y + size, center.z - size * 1.6)
        rim.look(at: center)
        root.addChildNode(rim)

        // Shadow catcher: only the shadow is drawn, the card's background shows through.
        let floor = SCNFloor()
        floor.reflectivity = 0
        let fm = SCNMaterial()
        fm.lightingModel = .shadowOnly
        fm.diffuse.contents = UIColor.white
        floor.materials = [fm]
        let floorNode = SCNNode(geometry: floor)
        floorNode.position = SCNVector3(0, minV.y + 0.0004, 0)
        floorNode.name = "_floor"
        root.addChildNode(floorNode)

        let camera = SCNCamera()
        camera.zNear = 0.005
        camera.zFar = 20
        camera.fieldOfView = 30
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -0.2
        camera.bloomIntensity = 0.25
        camera.bloomThreshold = 1.2
        camera.bloomBlurRadius = 6
        camera.screenSpaceAmbientOcclusionIntensity = 0.9
        camera.screenSpaceAmbientOcclusionRadius = 0.012
        camera.screenSpaceAmbientOcclusionNormalThreshold = 0.3
        camera.screenSpaceAmbientOcclusionDepthThreshold = 0.05
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(center.x + size * 1.35, center.y + size * 0.75, center.z + size * 1.95)
        cameraNode.look(at: SCNVector3(center.x, center.y - size * 0.05, center.z))
        root.addChildNode(cameraNode)
        view.pointOfView = cameraNode
        view.defaultCameraController.target = center
    }

    /// A soft studio: bright overhead softbox, light-grey walls, darker floor (equirectangular, 256 x 128).
    private static func studioEnvironment() -> UIImage {
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

    @MainActor
    final class Coordinator: NSObject {
        var parent: RobotSceneView
        weak var view: SCNView?
        private var nodes: [String: SCNNode] = [:]       // PartKey.norm(id) -> node
        private var applied: [String: String] = [:]
        private var screen: SCNMaterial?
        private var faceTimer: Timer?
        private let started = Date()
        private var faceState: String?
        private var faceSince = Date()
        private var coverOpacity: CGFloat = 1

        init(_ parent: RobotSceneView) { self.parent = parent }

        func index(_ root: SCNNode) {
            let names = Set(PartCatalog.all.compactMap(\.node))
            root.enumerateHierarchy { node, _ in
                if let name = node.name, names.contains(name) {
                    self.nodes[PartKey.norm(name)] = node
                    // own copies of the materials: the USD shares one material between many parts, and a glow
                    // on one part must not light up the others
                    node.enumerateHierarchy { n, _ in
                        guard let geo = n.geometry?.copy() as? SCNGeometry else { return }
                        geo.materials = geo.materials.map { ($0.copy() as? SCNMaterial) ?? $0 }
                        n.geometry = geo
                    }
                }
                if node.name == "LCD_screen", let m = node.geometry?.firstMaterial {
                    m.lightingModel = .constant
                    m.diffuse.contents = UIColor.black
                    m.diffuse.wrapS = .clamp
                    m.diffuse.wrapT = .clamp
                    m.isDoubleSided = false
                    self.screen = m
                }
            }
        }

        // MARK: Face on the screen (10 frames a second, like the LCD)

        func startFace() {
            drawFace(force: true)
            faceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.drawFace() }
            }
        }

        func stopFace() {
            faceTimer?.invalidate()
            faceTimer = nil
        }

        private func drawFace(force: Bool = false) {
            guard let screen, force || view?.window != nil else { return }   // only while on screen
            let state = parent.face
            if state != faceState {
                faceState = state
                faceSince = Date()
            }
            let now = Date()
            screen.diffuse.contents = FaceRenderer.image(state: state, elapsed: now.timeIntervalSince(started) + 6,
                                                          stateElapsed: now.timeIntervalSince(faceSince), scale: 1.5,
                                                          note: parent.note)
        }

        // MARK: Taps

        private func partKey(for node: SCNNode) -> String? {
            var n: SCNNode? = node
            while let current = n {
                if let name = current.name, nodes[PartKey.norm(name)] != nil { return PartKey.norm(name) }
                n = current.parent
            }
            return nil
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let hits = view.hitTest(gesture.location(in: view),
                                    options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: true])
            let keys = hits.compactMap { partKey(for: $0.node) }.filter { $0 != "a03cover" || coverOpacity > 0 }
            guard let first = keys.first else { return }
            if first == "a03cover" {
                if coverOpacity >= 0.99, let onCover = parent.onCoverTap { onCover(); return }
                // see-through cover: pick what is behind it
                if let behind = keys.first(where: { $0 != "a03cover" }), let id = PartCatalog.part(behind)?.id {
                    parent.onTap?(id); return
                }
            }
            if let id = PartCatalog.part(first)?.id { parent.onTap?(id) }
        }

        // MARK: Status colours and the cover

        func apply() {
            let selected = parent.selected.map(PartKey.norm)
            let insideIssue = parent.statuses.contains { key, s in (s == "fault" || s == "warn") && !RobotSceneView.outside.contains(key) }
            let insideSelected = selected.map { !RobotSceneView.outside.contains($0) } ?? false
            let target: CGFloat = !parent.showCover ? 0 : ((insideIssue || insideSelected) ? 0.22 : 1)
            if let cover = nodes["a03cover"], target != coverOpacity {
                coverOpacity = target
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.35
                cover.opacity = target          // no completion block: SceneKit calls it off the main thread
                SCNTransaction.commit()
            }
            for (key, node) in nodes {
                let status = key == selected ? "selected" : (parent.statuses[key] ?? "")
                guard applied[key] != status else { continue }
                applied[key] = status
                let color: UIColor
                switch status {
                case "selected": color = UIColor(red: 0.93, green: 0.47, blue: 0.22, alpha: 1)
                case "fault": color = UIColor(red: 0.90, green: 0.15, blue: 0.12, alpha: 1)
                case "warn": color = UIColor(red: 0.95, green: 0.60, blue: 0.10, alpha: 1)
                default: color = .black
                }
                node.enumerateHierarchy { n, _ in
                    guard n.name != "LCD_screen" else { return }
                    for material in n.geometry?.materials ?? [] {
                        material.emission.contents = color
                        material.emission.intensity = color == .black ? 0 : 0.7
                    }
                }
            }
        }
    }
}
