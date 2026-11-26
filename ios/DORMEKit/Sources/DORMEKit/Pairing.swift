import CryptoKit
import Foundation

/// The QR the robot shows while pairing: DORME1:<6 digits>:<robot X25519 key>:<128-bit token>, base64url.
/// The digits pair the app over Wi-Fi. The key and token seal Wi-Fi details sent over Bluetooth
/// (pi/dorme_coord/provision.py), so the password never crosses the air in the clear and there is
/// nothing short enough to guess.
public struct PairingQR: Equatable, Sendable {
    public let code: String
    public let robotKey: Data
    public let token: Data

    public init?(_ text: String) {
        let parts = text.split(separator: ":").map(String.init)
        guard parts.count == 4, parts[0] == "DORME1", parts[1].count == 6, parts[1].allSatisfy(\.isNumber),
              let key = Data(base64URL: parts[2]), key.count == 32,
              let token = Data(base64URL: parts[3]), token.count == 16 else { return nil }
        code = parts[1]
        robotKey = key
        self.token = token
    }

    public init(code: String, robotKey: Data, token: Data) {
        self.code = code; self.robotKey = robotKey; self.token = token
    }
}

public enum WifiSeal {
    public static let info = Data("dorme-wifi-v1".utf8)

    /// Seals {"ssid", "psk"} or {"ssid", "eap": {...}} for the robot's Bluetooth Wi-Fi characteristic.
    public static func seal(_ credentials: [String: Any], for qr: PairingQR) throws -> Data {
        let plain = try JSONSerialization.data(withJSONObject: credentials)
        return try seal(plain, for: qr, ephemeral: Curve25519.KeyAgreement.PrivateKey(), nonce: AES.GCM.Nonce())
    }

    /// phone_public(32) | nonce(12) | ciphertext | tag(16), as pi/dorme_coord/provision.py opens it.
    public static func seal(_ plain: Data, for qr: PairingQR, ephemeral mine: Curve25519.KeyAgreement.PrivateKey,
                            nonce: AES.GCM.Nonce) throws -> Data {
        let robot = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: qr.robotKey)
        let shared = try mine.sharedSecretFromKeyAgreement(with: robot)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: qr.token, sharedInfo: info, outputByteCount: 32)
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce, authenticating: info)
        var out = Data()
        out.append(mine.publicKey.rawRepresentation)
        out.append(nonce.withUnsafeBytes { Data($0) })
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }
}

public extension Data {
    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        self.init(base64Encoded: s)
    }

    init?(hex: String) {
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            guard let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex), let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        self.init(bytes)
    }
}

// MARK: - Bluetooth pairing without a code (2026-11-26, pi/dorme_coord/provision.py ble_hello)

/// What the robot seals into its Bluetooth pairing reply: a token and every way to reach it.
public struct BLEWelcome: Codable, Equatable, Sendable {
    public struct Hotspot: Codable, Equatable, Sendable {
        public let ssid: String
        public let psk: String?
        public let ip: String?
    }
    public let v: Int
    public let token: String
    public let name: String?
    public let port: Int?
    public let lan: [String]?
    public let ssid: String?
    public let ts: String?          // Tailscale MagicDNS name
    public let tsip: [String]?      // Tailscale addresses
    public let ap: Hotspot?         // the robot's own Wi-Fi for places with no Wi-Fi
}

/// Phone side of the Bluetooth pairing: X25519 with a fresh key each time, HKDF-SHA256 (salt = phone key |
/// robot key, info "dorme-ble-v2"), AES-256-GCM. The same session key seals the Wi-Fi password later.
public struct BLEPairing: Sendable {
    /// v3 (2026-11-26): pairing needs the code on DORM-E's screen again. The phone proves it knows the code
    /// (HMAC with the pairing key) without sending it; see pi/dorme_coord/provision.py.
    public static let info = Data("dorme-ble-v3".utf8)
    public static let proofLabel = Data("dorme-pair-code:".utf8)
    public static let wifiInfo = Data("dorme-wifi-v2".utf8)
    public let privateKey: Curve25519.KeyAgreement.PrivateKey
    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey = .init()) { self.privateKey = privateKey }

    /// Written to the pair characteristic: phone key (32) | phone name (UTF-8, at most 40 bytes).
    public func hello(name: String) -> Data {
        var out = publicKey
        var short = name
        while short.utf8.count > 40 { short.removeLast() }     // whole characters only
        out.append(Data(short.utf8))
        return out
    }

    /// The pairing key shared with this robot key (HKDF-SHA256, salt phone key | robot key).
    public func key(robotPublic: Data) throws -> SymmetricKey {
        let robot = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: robotPublic)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: robot)
        var salt = publicKey
        salt.append(robotPublic)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Self.info, outputByteCount: 32)
    }

    /// HMAC-SHA256(pairing key, "dorme-pair-code:" + code): shows the robot this phone saw the code.
    public func proof(code: String, robotPublic: Data) throws -> Data {
        var msg = Self.proofLabel
        msg.append(Data(code.utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: try key(robotPublic: robotPublic)))
    }

    /// Step 2, written to the pair characteristic: phone key (32) | 0x00 | proof (32).
    public func prove(code: String, robotPublic: Data) throws -> Data {
        var out = publicKey
        out.append(0)
        out.append(try proof(code: code, robotPublic: robotPublic))
        return out
    }

    /// Opens robot key (32) | nonce (12) | sealed welcome. -> welcome and the session key.
    public func open(_ blob: Data) throws -> (BLEWelcome, SymmetricKey) {
        guard blob.count > 32 + 12 + 16 else { throw CryptoKitError.incorrectParameterSize }
        let b = Data(blob)
        let key = try key(robotPublic: Data(b.prefix(32)))
        let box = try AES.GCM.SealedBox(combined: b.dropFirst(32))
        let plain = try AES.GCM.open(box, using: key, authenticating: Self.info)
        return (try JSONDecoder().decode(BLEWelcome.self, from: plain), key)
    }

    /// Seals Wi-Fi details for the wifi characteristic: phone key | nonce | ciphertext | tag.
    public func sealWifi(_ credentials: [String: Any], key: SymmetricKey, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> Data {
        try sealWifi(JSONSerialization.data(withJSONObject: credentials), key: key, nonce: nonce)
    }

    public func sealWifi(_ plain: Data, key: SymmetricKey, nonce: AES.GCM.Nonce) throws -> Data {
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce, authenticating: Self.wifiInfo)
        var out = publicKey
        out.append(nonce.withUnsafeBytes { Data($0) })
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }
}
