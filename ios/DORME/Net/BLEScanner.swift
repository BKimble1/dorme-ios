import CoreBluetooth
import Foundation

/// GATT layout shared with pi/dorme_coord/api.py (BLE_* UUIDs). Not actor-isolated.
enum DormeBLE {
    static let service = CBUUID(string: "6f1e0001-4c2b-4b7e-9d8a-d0a7e0b10001")
    static let statusChar = CBUUID(string: "6f1e0002-4c2b-4b7e-9d8a-d0a7e0b10001")
    static let setupChar = CBUUID(string: "6f1e0003-4c2b-4b7e-9d8a-d0a7e0b10001")
    static let commandChar = CBUUID(string: "6f1e0004-4c2b-4b7e-9d8a-d0a7e0b10001")
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
        var lastSeen = Date()
    }

    private(set) var devices: [Nearby] = []
    private(set) var radio: String = "Not started"
    private(set) var lastMessage: String?

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var helper: Helper?
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var commands: [UUID: CBCharacteristic] = [:]
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

        func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
            for s in peripheral.services ?? [] where s.uuid == DormeBLE.service {
                peripheral.discoverCharacteristics([DormeBLE.statusChar, DormeBLE.setupChar, DormeBLE.commandChar], for: s)
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
