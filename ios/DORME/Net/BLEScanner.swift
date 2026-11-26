import CoreBluetooth
import Foundation

/// GATT layout shared with pi/dorme_coord/api.py (BLE_* UUIDs). Not actor-isolated.
enum DormeBLE {
    static let service = CBUUID(string: "6f1e0001-4c2b-4b7e-9d8a-d0a7e0b10001")
    static let statusChar = CBUUID(string: "6f1e0002-4c2b-4b7e-9d8a-d0a7e0b10001")
    static let setupChar = CBUUID(string: "6f1e0003-4c2b-4b7e-9d8a-d0a7e0b10001")
    static let commandChar = CBUUID(string: "6f1e0004-4c2b-4b7e-9d8a-d0a7e0b10001")
    static let wifiChar = CBUUID(string: "6f1e0005-4c2b-4b7e-9d8a-d0a7e0b10001")
    static let resultChar = CBUUID(string: "6f1e0006-4c2b-4b7e-9d8a-d0a7e0b10001")
}

/// Nearby discovery over Bluetooth LE: finds robots advertising the DORM-E service, reads their
/// compact status and the Wi-Fi API address, and can send STOP. Driving never goes over BLE.
/// The Pi side (pi/dorme_coord/ble_bridge.py) is UNTESTED on hardware.
@MainActor
@Observable
final class BLEScanner {
    struct Nearby: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
        var voltage: Double?
        var esp: String?
        var fault: String?
        var simulated = false
        var addresses: [String] = []
        var port: Int?
        var canStop = false
        var canSetUpWifi = false
        var wifiName: String?
        var wifiIP: String?
        var lastSeen = Date()
    }

    /// Outcome of a Bluetooth Wi-Fi setup, from the robot's result characteristic.
    struct SetupResult: Equatable {
        var ok: Bool?            // nil while joining
        var message: String?
        var ssid: String?
        var ipv4: String?
    }

    private(set) var devices: [Nearby] = []
    private(set) var radio: String = "Not started"
    private(set) var lastMessage: String?
    private(set) var results: [UUID: SetupResult] = [:]

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var helper: Helper?
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var commands: [UUID: CBCharacteristic] = [:]
    @ObservationIgnored private var wifiChars: [UUID: CBCharacteristic] = [:]
    @ObservationIgnored private var wantScan = false

    func start() {
        wantScan = true
        if central == nil {
            let helper = Helper(owner: self)
            self.helper = helper
            central = CBCentralManager(delegate: helper, queue: .main)
        } else {
            scanIfReady()
        }
    }

    func stopScanning() {
        wantScan = false
        central?.stopScan()
        for p in peripherals.values { central?.cancelPeripheralConnection(p) }
    }

    func sendStop(_ id: UUID) {
        guard let p = peripherals[id], let ch = commands[id] else {
            lastMessage = "Not connected to that robot over Bluetooth yet."
            return
        }
        p.writeValue(Data("STOP".utf8), for: ch, type: .withResponse)
        lastMessage = "Stop sent over Bluetooth."
    }

    /// Ask the robot to show its pairing code and QR on its own screen.
    func requestCode(_ id: UUID) {
        guard let p = peripherals[id], let ch = commands[id] else { return }
        p.writeValue(Data("CODE".utf8), for: ch, type: .withResponse)
    }

    /// Send sealed Wi-Fi details in framed chunks: byte 0 = index << 1 | last.
    func sendWifi(_ id: UUID, sealed: Data) -> Bool {
        guard let p = peripherals[id], p.state == .connected, let ch = wifiChars[id] else {
            results[id] = SetupResult(ok: false, message: "Lost the Bluetooth link. Move closer and try again.")
            return false
        }
        let limit = max(20, min(180, p.maximumWriteValueLength(for: .withResponse) - 1))
        var chunks: [Data] = []
        var offset = 0
        while offset < sealed.count {
            let end = min(offset + limit, sealed.count)
            chunks.append(sealed.subdata(in: offset..<end))
            offset = end
        }
        for (i, chunk) in chunks.enumerated() {
            var frame = Data([UInt8((i << 1) | (i == chunks.count - 1 ? 1 : 0))])
            frame.append(chunk)
            p.writeValue(frame, for: ch, type: .withResponse)
        }
        results[id] = SetupResult(ok: nil, message: "Sending")
        return true
    }

    func clearResult(_ id: UUID) { results[id] = nil }

    /// The link dropped (robot rebooted, out of range): forget its characteristics and connect again.
    fileprivate func lost(_ p: CBPeripheral) {
        commands[p.identifier] = nil
        wifiChars[p.identifier] = nil
        if let i = devices.firstIndex(where: { $0.id == p.identifier }) {
            devices[i].canStop = false
            devices[i].canSetUpWifi = false
        }
        if results[p.identifier]?.ok == nil, results[p.identifier] != nil {
            results[p.identifier] = SetupResult(ok: false, message: "Bluetooth link lost. If DORM-E restarted, try again.")
        }
        if wantScan { central?.connect(p) }
    }

    fileprivate func scanIfReady() {
        guard let central else { return }
        switch central.state {
        case .poweredOn:
            radio = wantScan ? "Scanning" : "Ready"
            if wantScan { central.scanForPeripherals(withServices: [DormeBLE.service]) }
        case .poweredOff: radio = "Bluetooth is off"
        case .unauthorized: radio = "Bluetooth permission denied"
        case .unsupported: radio = "Bluetooth LE not supported"
        default: radio = "Starting"
        }
    }

    fileprivate func discovered(_ p: CBPeripheral, name: String?, rssi: Int) {
        peripherals[p.identifier] = p
        if let i = devices.firstIndex(where: { $0.id == p.identifier }) {
            devices[i].rssi = rssi
            devices[i].lastSeen = Date()
        } else {
            devices.append(Nearby(id: p.identifier, name: name ?? p.name ?? "DORM-E", rssi: rssi))
            p.delegate = helper
            central?.connect(p)
        }
    }

    fileprivate func characteristicsFound(_ p: CBPeripheral, _ chars: [CBCharacteristic]) {
        for ch in chars {
            switch ch.uuid {
            case DormeBLE.statusChar:
                p.readValue(for: ch)
                if ch.properties.contains(.notify) { p.setNotifyValue(true, for: ch) }
            case DormeBLE.setupChar:
                p.readValue(for: ch)
            case DormeBLE.commandChar:
                commands[p.identifier] = ch
                if let i = devices.firstIndex(where: { $0.id == p.identifier }) { devices[i].canStop = true }
            case DormeBLE.wifiChar:
                wifiChars[p.identifier] = ch
                if let i = devices.firstIndex(where: { $0.id == p.identifier }) { devices[i].canSetUpWifi = true }
            case DormeBLE.resultChar:
                if ch.properties.contains(.notify) { p.setNotifyValue(true, for: ch) }
            default: break
            }
        }
    }

    fileprivate func valueUpdated(_ p: CBPeripheral, _ ch: CBCharacteristic) {
        guard let data = ch.value, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let i = devices.firstIndex(where: { $0.id == p.identifier }) else { return }
        if ch.uuid == DormeBLE.statusChar {
            devices[i].voltage = obj["bv"] as? Double
            devices[i].esp = obj["esp"] as? String
            devices[i].fault = obj["f"] as? String
            devices[i].simulated = (obj["sim"] as? Int) == 1
            if let n = obj["n"] as? String { devices[i].name = n }
            devices[i].wifiName = obj["w"] as? String
            devices[i].wifiIP = obj["ip"] as? String
        } else if ch.uuid == DormeBLE.resultChar {
            results[p.identifier] = SetupResult(ok: obj["ok"] as? Bool, message: obj["message"] as? String,
                                                 ssid: obj["ssid"] as? String,
                                                 ipv4: (obj["ipv4"] as? [String])?.first)
        } else if ch.uuid == DormeBLE.setupChar {
            devices[i].addresses = obj["addrs"] as? [String] ?? []
            devices[i].port = obj["port"] as? Int
        }
        devices[i].lastSeen = Date()
    }

    /// CoreBluetooth delegate. Runs on the main queue (see CBCentralManager init above).
    private final class Helper: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
        weak var owner: BLEScanner?
        init(owner: BLEScanner) { self.owner = owner }

        func centralManagerDidUpdateState(_ central: CBCentralManager) {
            MainActor.assumeIsolated { owner?.scanIfReady() }
        }

        func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                            advertisementData: [String: Any], rssi RSSI: NSNumber) {
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let rssi = RSSI.intValue
            MainActor.assumeIsolated { owner?.discovered(peripheral, name: name, rssi: rssi) }
        }

        func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
            peripheral.discoverServices([DormeBLE.service])
        }

        func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
            MainActor.assumeIsolated { owner?.lost(peripheral) }
        }

        func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
            MainActor.assumeIsolated { owner?.lost(peripheral) }
        }

        func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
            for s in peripheral.services ?? [] where s.uuid == DormeBLE.service {
                peripheral.discoverCharacteristics([DormeBLE.statusChar, DormeBLE.setupChar, DormeBLE.commandChar,
                                                    DormeBLE.wifiChar, DormeBLE.resultChar], for: s)
            }
        }

        func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
            let chars = service.characteristics ?? []
            MainActor.assumeIsolated { owner?.characteristicsFound(peripheral, chars) }
        }

        func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
            MainActor.assumeIsolated { owner?.valueUpdated(peripheral, characteristic) }
        }
    }
}
