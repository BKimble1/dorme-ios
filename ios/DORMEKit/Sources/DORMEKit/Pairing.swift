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
