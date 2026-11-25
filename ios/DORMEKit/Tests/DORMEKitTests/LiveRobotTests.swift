import Foundation
import XCTest
@testable import DORMEKit

/// Runs only in CI, against the real coordinator code in simulator mode (pi/dorme_coord, --backend sim),
/// using Apple's URLSession / URLSessionWebSocketTask: the same networking stack the iPhone app uses.
/// Env: DORME_SIM_URL (http://127.0.0.1:port), DORME_SIM_PIN, DORME_SIM_FACE (the simulator's face state file).
final class LiveRobotTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func post(_ url: String, _ body: [String: Any], token: String? = nil) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, json(data))
    }

    func testPairStreamAndDecodeRealState() async throws {
        guard let base = env["DORME_SIM_URL"], let pin = env["DORME_SIM_PIN"] else { throw XCTSkip("No simulator robot") }

        let (infoData, infoResponse) = try await URLSession.shared.data(from: URL(string: base + "/api/v1/info")!)
        XCTAssertEqual((infoResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(json(infoData)["name"] as? String, "DORM-E")

        let (status, pairReply) = try await post(base + "/api/v1/pair", ["pin": pin, "client_name": "ci"])
        XCTAssertEqual(status, 200, "\(pairReply)")
        let token = try XCTUnwrap((pairReply["result"] as? [String: Any])?["token"] as? String)

        var request = URLRequest(url: URL(string: base.replacingOccurrences(of: "http://", with: "ws://") + "/api/v1/ws")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(token, forHTTPHeaderField: "X-DORME-Token")      // exactly what the app sends
        request.timeoutInterval = 5          // the app uses the same 5 s
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        var types: [String] = []
        var hello: [String: Any]?
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, types.filter({ $0 == "state" }).count < 8 {
            let message = try await task.receive()
            guard case .string(let text) = message else { continue }
            let obj = json(Data(text.utf8))
            let type = obj["type"] as? String ?? "?"
            if type == "hello" { hello = obj }
            types.append(type)
            if types.count % 4 == 0 { task.sendPing { _ in } }
        }
        task.cancel(with: .normalClosure, reason: nil)
        XCTAssertEqual(types.first, "hello")
        XCTAssertGreaterThanOrEqual(types.filter { $0 == "state" }.count, 8, "\(types)")

        let stateJSON = try JSONSerialization.data(withJSONObject: try XCTUnwrap(hello?["state"]))
        let state = try DORMEJSON.decoder.decode(RobotState.self, from: stateJSON)
        let health = try XCTUnwrap(state.health, "robot sent no health")
        XCTAssertNotNil(health.part("ESP32_U7"))
        XCTAssertNotNil(health.part("PI4"))

        var sysReq = URLRequest(url: URL(string: base + "/api/v1/system")!)
        sysReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (sysData, _) = try await URLSession.shared.data(for: sysReq)
        let system = try DORMEJSON.decoder.decode(SystemReport.self, from: sysData)
        XCTAssertTrue(system.parts.contains { $0.id == "PI4" })
    }

    func testSealedWifiOpensOnTheRobot() async throws {
        guard let base = env["DORME_SIM_URL"], let facePath = env["DORME_SIM_FACE"] else { throw XCTSkip("No simulator robot") }
        // What the BLE bridge does when the phone writes CODE: the robot shows its code and QR.
        let (codeStatus, _) = try await post(base + "/api/v1/ble/code", [:])
        XCTAssertEqual(codeStatus, 200)
        try await Task.sleep(nanoseconds: 500_000_000)
        // In the simulator the "screen" is a file; read the QR the robot would draw.
        let face = json(try Data(contentsOf: URL(fileURLWithPath: facePath)))
        let qr = try XCTUnwrap(PairingQR(try XCTUnwrap(face["qr"] as? String)), "no QR on the robot's screen: \(face)")
        let sealed = try WifiSeal.seal(["ssid": "CI Network", "psk": "correct horse battery"], for: qr)
        let (status, reply) = try await post(base + "/api/v1/ble/wifi", ["blob": sealed.base64EncodedString()])
        XCTAssertEqual(status, 200, "\(reply)")
        XCTAssertEqual(reply["ok"] as? Bool, true)
        // The code is used up: the same sealed blob is refused now.
        let (again, _) = try await post(base + "/api/v1/ble/wifi", ["blob": sealed.base64EncodedString()])
        XCTAssertNotEqual(again, 200)
    }
}
