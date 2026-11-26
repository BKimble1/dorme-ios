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

    /// Everyday words that should find a part even though they are not in its name.
    static let keywords: [String: [String]] = [
        "PI4": ["pi", "computer", "brain", "cpu", "temperature", "temp", "heat", "memory", "storage"],
        "ESP32_U7": ["controller", "microcontroller", "firmware", "esp", "safety"],
        "LCD": ["screen", "display", "face", "eyes"],
        "CAMERA": ["camera", "video", "vision"],
        "SONAR": ["distance", "ultrasonic", "obstacle", "range"],
        "BATTERY": ["battery", "power", "voltage", "charge"],
        "INA219_U9": ["current", "voltage", "power", "battery"],
        "J_CHG": ["charge", "charger", "charging", "plug"],
        "S2_SWITCH": ["button", "power", "on", "off"],
        "FAN": ["fan", "cooling", "temperature", "heat"],
        "AUDIO_U16": ["microphone", "mic", "voice", "sound"],
        "SPEAKER": ["sound", "audio", "chime"],
        "M1": ["motor", "drive", "wheel"], "M2": ["motor", "drive", "wheel"],
        "M3": ["motor", "drive", "wheel"], "M4": ["motor", "drive", "wheel"],
        "MD20A_U4": ["motor", "driver", "drive"], "MD20A_U5": ["motor", "driver", "drive"],
        "W1": ["tire", "tyre", "drive"], "W2": ["tire", "tyre", "drive"], "W3": ["tire", "tyre", "drive"], "W4": ["tire", "tyre", "drive"],
        "WIFI": ["wifi", "wireless", "network", "internet", "signal"],
        "BLUETOOTH": ["ble", "bluetooth", "wireless", "setup"],
        "REMOTE": ["tailscale", "remote", "internet", "vpn", "anywhere"],
        "A03_cover": ["shell", "body", "case", "lid"],
        "A01_chassis": ["frame", "base", "body"],
    ]

    static func search(_ query: String) -> [CatalogPart] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        let words = q.split(separator: " ").map(String.init)
        func hay(_ p: CatalogPart) -> String {
            ([p.name, p.id, p.category] + (keywords[p.id] ?? [])).joined(separator: " ").lowercased()
        }
        let hits = all.filter { p in let h = hay(p); return words.allSatisfy { h.contains($0) } }
        // name matches first
        return hits.sorted { a, b in
            let an = a.name.lowercased().contains(q), bn = b.name.lowercased().contains(q)
            return an && !bn
        }
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
    static func row(_ rawKey: String, _ value: JSONValue) -> (String, String) {
        // keys may arrive snake_case (dictionary keys are not converted by the decoder): disk_free_mb -> diskFreeMb
        let parts = rawKey.split(separator: "_").map(String.init)
        let key = parts.isEmpty ? rawKey : parts[0] + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
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
        let plain = rawKey.replacingOccurrences(of: "_", with: " ")
        let (label, unit) = labels[key] ?? (plain.prefix(1).uppercased() + plain.dropFirst(), "")
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
