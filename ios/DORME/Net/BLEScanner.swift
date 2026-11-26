import CoreBluetooth
import CryptoKit
import DORMEKit
import Foundation

/// GATT layout shared with pi/dorme_coord/api.py (BLE_* UUIDs). Not actor-isolated.
enum DormeBLE {
    static let service = CBUUID(string: "6f1e0001-4c2b-4b7e-9d8a-d0a7e0b10001")
    static let statusChar = CBUUID(string: "6f1e0002-4c2b-4b7e-9d8a-d0a7e0b10001")
    static let setupChar = CBUUID(string: "6f1e0003-4c2b-4b7e-9d8a-d0a7e0b10001")
    static let commandChar = CBUUID(string: "6f1e0004-4c2b-4b7e-9d8a-d0a7e0b10001")
    static let wifiChar = CBUUID(string: "6f1e0005-4c2b-4b7e-9d8a-d0a7e0b10001")
    static let resultChar = CBUUID(string: "6f1e0006-4c2b-4b7e-9d8a-d0a7e0b10001")
    static let pairChar = CBUUID(string: "6f1e0007-4c2b-4b7e-9d8a-d0a7e0b10001")      // 2026-11-26
    static let networksChar = CBUUID(string: "6f1e0008-4c2b-4b7e-9d8a-d0a7e0b10001")
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
        var canPair = false
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
    /// Wi-Fi networks each robot can see (after scanNetworks), strongest first.
    private(set) var networks: [UUID: [ScannedNetwork]] = [:]
    private(set) var scanning: Set<UUID> = []

    struct ScannedNetwork: Identifiable, Equatable {
        var id: String { ssid }
        let ssid: String
        let signal: Int?
        let security: String          // "open", "password", "enterprise"
    }

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var helper: Helper?
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var commands: [UUID: CBCharacteristic] = [:]
    @ObservationIgnored private var wifiChars: [UUID: CBCharacteristic] = [:]
    @ObservationIgnored private var pairChars: [UUID: CBCharacteristic] = [:]
    @ObservationIgnored private var networkChars: [UUID: CBCharacteristic] = [:]
    @ObservationIgnored private var pairWaiters: [UUID: CheckedContinuation<Data, Never>] = [:]
    /// Session keys from Bluetooth pairing; they seal the Wi-Fi password (DORMEKit BLEPairing).
    @ObservationIgnored private var sessions: [UUID: (pairing: BLEPairing, key: SymmetricKey)] = [:]
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

    enum PairOutcome {
        case paired(BLEWelcome)
        case refused(code: String, message: String)
    }

    /// Pair over Bluetooth with no code (robot side: ble_bridge.py "pair"). Works while DORM-E's pairing is open:
    /// for 10 minutes after it is switched on, while no phone is paired, or after "Add another phone".
    func pair(_ id: UUID, phoneName: String) async -> PairOutcome {
        guard let p = peripherals[id], p.state == .connected, let ch = pairChars[id] else {
            return .refused(code: "NO_LINK", message: "Not connected to DORM-E over Bluetooth yet. Move closer and try again.")
        }
        let pairing = BLEPairing()
        pairWaiters[id]?.resume(returning: Data())
        let reply: Data = await withCheckedContinuation { cont in
            pairWaiters[id] = cont
            writeFramed(pairing.hello(name: phoneName), to: ch, on: p)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if let waiter = self?.pairWaiters.removeValue(forKey: id) { waiter.resume(returning: Data()) }
            }
        }
        guard let first = reply.first else {
            return .refused(code: "TIMEOUT", message: "DORM-E did not answer over Bluetooth. Move closer and try again.")
        }
        if first == 1, let opened = try? pairing.open(reply.dropFirst()) {
            sessions[id] = (pairing, opened.1)
            pairedOverBluetooth.insert(id)
            return .paired(opened.0)
        }
        let info = (try? JSONSerialization.jsonObject(with: Data(reply.dropFirst()))) as? [String: Any]
        let code = info?["code"] as? String ?? "REFUSED"
        let message = (info?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (Ack.messages[code] ?? "DORM-E refused to pair.")
        return .refused(code: code, message: message)
    }

    /// Robots this phone holds a Bluetooth pairing session with (observable, unlike the keys themselves).
    private(set) var pairedOverBluetooth: Set<UUID> = []

    /// Ask the robot to list the Wi-Fi networks it can see; the answer arrives in `networks[id]`.
    func scanNetworks(_ id: UUID) {
        guard let p = peripherals[id], let ch = commands[id] else { return }
        scanning.insert(id)
        p.writeValue(Data("SCAN".utf8), for: ch, type: .withResponse)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            self?.scanning.remove(id)
        }
    }

    /// Seal Wi-Fi details with the Bluetooth pairing session and send them.
    func sendWifi(_ id: UUID, credentials: [String: Any]) -> Bool {
        guard let session = sessions[id], let sealed = try? session.pairing.sealWifi(credentials, key: session.key) else {
            results[id] = SetupResult(ok: false, message: "Pair with DORM-E over Bluetooth first.")
            return false
        }
        return sendWifi(id, sealed: sealed)
    }

    private func writeFramed(_ data: Data, to ch: CBCharacteristic, on p: CBPeripheral) {
        let limit = max(20, min(180, p.maximumWriteValueLength(for: .withResponse) - 1))
        var offset = 0, index = 0
        repeat {
            let end = min(offset + limit, data.count)
            var frame = Data([UInt8((index << 1) | (end == data.count ? 1 : 0))])
            frame.append(data.subdata(in: offset..<end))
            p.writeValue(frame, for: ch, type: .withResponse)
            offset = end
            index += 1
        } while offset < data.count
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
        pairChars[p.identifier] = nil
        networkChars[p.identifier] = nil
        scanning.remove(p.identifier)
        pairWaiters.removeValue(forKey: p.identifier)?.resume(returning: Data())
        if let i = devices.firstIndex(where: { $0.id == p.identifier }) {
            devices[i].canStop = false
            devices[i].canSetUpWifi = false
            devices[i].canPair = false
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
            case DormeBLE.pairChar:
                pairChars[p.identifier] = ch
                if ch.properties.contains(.notify) { p.setNotifyValue(true, for: ch) }
                if let i = devices.firstIndex(where: { $0.id == p.identifier }) { devices[i].canPair = true }
            case DormeBLE.networksChar:
                networkChars[p.identifier] = ch
                if ch.properties.contains(.notify) { p.setNotifyValue(true, for: ch) }
            default: break
            }
        }
    }

    fileprivate func valueUpdated(_ p: CBPeripheral, _ ch: CBCharacteristic) {
        // pair / networks: a 1-byte notification means "ready"; the full value (up to 512 bytes) is then read
        if ch.uuid == DormeBLE.pairChar || ch.uuid == DormeBLE.networksChar, let data = ch.value {
            if data.count <= 1 {
                p.readValue(for: ch)
            } else if ch.uuid == DormeBLE.pairChar {
                pairWaiters.removeValue(forKey: p.identifier)?.resume(returning: data)
            } else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rows = obj["n"] as? [[Any]] {
                networks[p.identifier] = rows.compactMap { row -> ScannedNetwork? in
                    guard let ssid = row.first as? String else { return nil }
                    let letter = row.count > 2 ? row[2] as? String : nil
                    let kind = letter == "o" ? "open" : (letter == "e" ? "enterprise" : "password")
                    return ScannedNetwork(ssid: ssid, signal: row.count > 1 ? row[1] as? Int : nil, security: kind)
                }
                scanning.remove(p.identifier)
            }
            return
        }
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
                                                    DormeBLE.wifiChar, DormeBLE.resultChar, DormeBLE.pairChar,
                                                    DormeBLE.networksChar], for: s)
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
