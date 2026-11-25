import SceneKit
import SwiftUI
import DORMEKit

/// The robot's 3D model (Resources/DORME_robot.usdz). Drag to rotate, pinch to zoom, tap a part.
/// Parts glow red or orange when the robot reports a fault or warning; the selected part glows in the accent.
struct RobotSceneView: UIViewRepresentable {
    /// Part status keyed by PartKey.norm(id).
    var statuses: [String: String] = [:]
    var selected: String?
    var showCover = true
    var onTap: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = true
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        if let url = Bundle.main.url(forResource: "DORME_robot", withExtension: "usdz"),
           let scene = try? SCNScene(url: url, options: nil) {
            view.scene = scene
            let (minV, maxV) = scene.rootNode.boundingBox
            let center = SCNVector3((minV.x + maxV.x) / 2, (minV.y + maxV.y) / 2, (minV.z + maxV.z) / 2)
            let size = max(maxV.x - minV.x, maxV.y - minV.y, maxV.z - minV.z)
            let camera = SCNCamera()
            camera.zNear = 0.005
            camera.zFar = 20
            camera.fieldOfView = 34
            let cameraNode = SCNNode()
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(center.x + size * 1.25, center.y + size * 0.85, center.z + size * 1.75)
            cameraNode.look(at: center)
            scene.rootNode.addChildNode(cameraNode)
            view.pointOfView = cameraNode
            view.defaultCameraController.target = center
            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 450
            scene.rootNode.addChildNode(ambient)
            context.coordinator.index(scene.rootNode)
        }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: RobotSceneView
        weak var view: SCNView?
        private var nodes: [String: SCNNode] = [:]       // PartKey.norm(id) -> node
        private var applied: [String: String] = [:]

        init(_ parent: RobotSceneView) { self.parent = parent }

        func index(_ root: SCNNode) {
            let names = Set(PartCatalog.all.compactMap(\.node))
            root.enumerateHierarchy { node, _ in
                if let name = node.name, names.contains(name) { self.nodes[PartKey.norm(name)] = node }
            }
        }

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
            let keys = hits.compactMap { partKey(for: $0.node) }
            // The see-through cover wraps everything: prefer what is behind it.
            guard let key = keys.first(where: { $0 != "a03cover" }) ?? keys.first,
                  let id = PartCatalog.part(key)?.id else { return }
            parent.onTap?(id)
        }

        func apply() {
            let selected = parent.selected.map(PartKey.norm)
            nodes["a03cover"]?.isHidden = !parent.showCover
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
                    for material in n.geometry?.materials ?? [] {
                        material.emission.contents = color
                        material.emission.intensity = color == .black ? 0 : 0.6
                    }
                }
            }
        }
    }
}
