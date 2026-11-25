import CryptoKit
import XCTest
@testable import DORMEKit

/// The vector below was produced by the robot's own Python code path (cryptography: X25519, HKDF-SHA256,
/// AES-GCM) with fixed keys, token and nonce. Matching it byte for byte proves the iPhone seals Wi-Fi details
/// exactly the way pi/dorme_coord/provision.py opens them.
final class PairingTests: XCTestCase {
    func testSealMatchesRobotVector() throws {
        let robotPub = Data(hex: "07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c")!
        let phone = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(hex: "65666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f8081828384")!)
        let token = Data(hex: "c8c9cacbcccdcecfd0d1d2d3d4d5d6d7")!
        let nonce = try AES.GCM.Nonce(data: Data(hex: "32333435363738393a3b3c3d")!)
        let plain = Data(#"{"psk":"correct horse","ssid":"Home"}"#.utf8)
        let qr = PairingQR(code: "123456", robotKey: robotPub, token: token)
        let blob = try WifiSeal.seal(plain, for: qr, ephemeral: phone, nonce: nonce)
        let expected = Data(hex: "5714769d116bf76436ae74bc793d2c30ad1903c59ac5273805c7e2698b410c3632333435363738393a3b3c3d9dd2759759dfce608800ed549da557153799598d8a686375ecf0d5500f7b6ff2f8d82ce7496d361b6c8fa18956e3c4770be0049f65")!
        XCTAssertEqual(blob, expected)
    }

    func testQRParsing() {
        let qr = PairingQR("DORME1:482915:B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9_AsrhtHHw:yMnKy8zNzs_Q0dLT1NXW1w")
        XCTAssertEqual(qr?.code, "482915")
        XCTAssertEqual(qr?.robotKey.count, 32)
        XCTAssertEqual(qr?.token.count, 16)
        XCTAssertNil(PairingQR("DORME1:48291:abc:def"))
        XCTAssertNil(PairingQR("https://example.com"))
    }

    func testHealthPartLookupSurvivesKeyConversion() throws {
        let json = #"{"overall":"fault","headline":"x","issues":[],"parts":{"ESP32_U7":{"s":"fault","t":"Link lost"},"A01_chassis":{"s":"none","t":"No sensor"}}}"#
        let h = try DORMEJSON.decoder.decode(HealthSummary.self, from: Data(json.utf8))
        XCTAssertEqual(h.part("ESP32_U7")?.s, "fault")
        XCTAssertEqual(h.part("A01_chassis")?.s, "none")
    }
}
