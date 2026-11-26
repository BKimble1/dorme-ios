import CryptoKit
import XCTest
@testable import DORMEKit

/// spec/fixtures/ble_pairing.json was made by the robot's Python code (pi/dorme_coord/provision.py) with fixed
/// keys and nonces. The phone must open the robot's reply and seal Wi-Fi details byte for byte the same way.
final class BLEPairingTests: XCTestCase {
    struct Fixture: Decodable {
        let phone_private_hex, phone_public_hex, session_key_hex, welcome_blob_hex: String
        let wifi_nonce_hex, wifi_plain_utf8, wifi_sealed_hex: String
        let welcome: BLEWelcome
    }

    func load() throws -> Fixture {
        let url = FixtureDecodingTests.fixtures.appendingPathComponent("ble_pairing.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testOpensTheRobotsWelcome() throws {
        let f = try load()
        let pairing = BLEPairing(privateKey: try .init(rawRepresentation: Data(hex: f.phone_private_hex)!))
        XCTAssertEqual(pairing.publicKey, Data(hex: f.phone_public_hex)!)
        let (welcome, key) = try pairing.open(Data(hex: f.welcome_blob_hex)!)
        XCTAssertEqual(welcome, f.welcome)
        XCTAssertEqual(welcome.ap?.ip, "10.42.0.1")
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }, Data(hex: f.session_key_hex)!)
    }

    func testSealsWifiLikeTheRobotExpects() throws {
        let f = try load()
        let pairing = BLEPairing(privateKey: try .init(rawRepresentation: Data(hex: f.phone_private_hex)!))
        let key = SymmetricKey(data: Data(hex: f.session_key_hex)!)
        let sealed = try pairing.sealWifi(Data(f.wifi_plain_utf8.utf8), key: key,
                                          nonce: try AES.GCM.Nonce(data: Data(hex: f.wifi_nonce_hex)!))
        XCTAssertEqual(sealed, Data(hex: f.wifi_sealed_hex)!)
    }

    func testTamperedWelcomeIsRejected() throws {
        let f = try load()
        let pairing = BLEPairing(privateKey: try .init(rawRepresentation: Data(hex: f.phone_private_hex)!))
        var blob = Data(hex: f.welcome_blob_hex)!
        blob[blob.count - 1] ^= 1
        XCTAssertThrowsError(try pairing.open(blob))
    }

    func testHelloCarriesKeyAndShortName() {
        let pairing = BLEPairing()
        let hello = pairing.hello(name: String(repeating: "é", count: 40))
        XCTAssertEqual(hello.prefix(32), pairing.publicKey)
        XCTAssertLessThanOrEqual(hello.count, 72)
    }
}
