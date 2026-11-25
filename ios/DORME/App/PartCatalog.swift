import Foundation
import DORMEKit

/// Every part the app knows: the 3D model's parts (Resources/robot_parts.json, generated from the CAD by
/// cad/export_app_model.py) plus the Pi's radios, which have no shape.
struct CatalogPart: Identifiable, Hashable, Decodable {
    let id: String
    let name: String
    let category: String
    let node: String?
}

enum PartCatalog {
    static let all: [CatalogPart] = {
        var list: [CatalogPart] = []
        if let url = Bundle.main.url(forResource: "robot_parts", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let parts = try? JSONDecoder().decode([CatalogPart].self, from: data) {
            list = parts
        }
        list += [CatalogPart(id: "WIFI", name: "Wi-Fi", category: "network", node: nil),
                 CatalogPart(id: "BLUETOOTH", name: "Bluetooth", category: "network", node: nil),
                 CatalogPart(id: "REMOTE", name: "Remote access", category: "network", node: nil)]
        return list
    }()

    static func part(_ id: String) -> CatalogPart? {
        let key = PartKey.norm(id)
        return all.first { PartKey.norm($0.id) == key }
    }

    static func name(_ id: String) -> String { part(id)?.name ?? id }

    static func search(_ query: String) -> [CatalogPart] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) || $0.category.lowercased().contains(q) }
    }
}

extension Level {
    /// Robot part status -> colour level.
    init(partStatus: String?) {
        switch partStatus {
        case "ok": self = .good
        case "warn": self = .warn
        case "fault": self = .bad
        default: self = .neutral
        }
    }
}

enum ValueFormat {
    /// Readable label and value for one entry of a part's `values` (keys arrive camelCased by the decoder).
    static func row(_ key: String, _ value: JSONValue) -> (String, String) {
        let labels: [String: (String, String)] = [
            "socTempC": ("Temperature", "°C"), "memAvailableMb": ("Free memory", "MB"), "diskFreeMb": ("Free storage", "MB"),
            "load1m": ("Load", ""), "uptimeS": ("Uptime", ""), "throttled": ("Throttling", ""),
            "ssid": ("Network", ""), "signalDbm": ("Signal", "dBm"), "ipv4": ("Address", ""),
            "tailnetName": ("Remote name", ""), "tailnetIps": ("Remote address", ""), "state": ("State", ""),
            "fault": ("Fault", ""), "firmware": ("Firmware", ""), "hbGapMaxMs": ("Longest heartbeat gap", "ms"),
            "statAgeMs": ("Last report", "ms ago"), "busV": ("Bus voltage", "V"), "voltageV": ("Voltage", "V"),
            "motorRailV": ("Motor rail", "V"), "distanceCm": ("Distance", "cm"), "reason": ("Note", ""),
            "card": ("Device", ""), "note": ("Note", ""), "pwm": ("Drive output", "%"), "service": ("Service", ""),
        ]
        let (label, unit) = labels[key] ?? (key.prefix(1).uppercased() + key.dropFirst(), "")
        var text: String
        switch value {
        case .number(let n):
            if key == "uptimeS" {
                let s = Int(n)
                text = s >= 86_400 ? "\(s / 86_400) d \(s % 86_400 / 3600) h" : (s >= 3600 ? "\(s / 3600) h \(s % 3600 / 60) min" : "\(s / 60) min")
                return (label, text)
            }
            text = n.rounded() == n ? String(Int(n)) : String(format: "%.2f", n)
        case .string(let s): text = s
        case .bool(let b): text = b ? "Yes" : "No"
        case .array(let a): text = a.map { $0.string ?? $0.double.map { String(format: "%g", $0) } ?? "–" }.joined(separator: ", ")
        default: text = "–"
        }
        return (label, unit.isEmpty || text == "–" ? text : "\(text) \(unit)")
    }
}
