import XCTest
@testable import DORMEKit

/// Decodes the shared fixtures in dorme_platform/spec/fixtures, the same files the Python tests
/// validate against the schema. NOT YET RUN: needs a Mac with Xcode (`swift test`).
final class FixtureDecodingTests: XCTestCase {
    static let fixtures: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // DORMEKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // DORMEKit
        .deletingLastPathComponent()   // ios
        .deletingLastPathComponent()   // dorme_platform
        .appendingPathComponent("spec/fixtures")

    func data(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
    }

    func testAllStateFixturesDecode() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.fixtures.path)
            .filter { $0.hasPrefix("state_") && $0.hasSuffix(".json") }
        XCTAssertGreaterThanOrEqual(names.count, 6)
        for name in names {
            let state = try DORMEJSON.decoder.decode(RobotState.self, from: data(name))
            XCTAssertNil(state.battery.percent, name)
            XCTAssertTrue(state.robot.simulated, name)
            XCTAssertEqual(state.motion.basis, "commanded", name)
        }
    }

    func testSpecificScenarios() throws {
        let bench = try DORMEJSON.decoder.decode(RobotState.self, from: data("state_bench_idle.json"))
        XCTAssertTrue(bench.robot.benchMode)
        XCTAssertEqual(bench.motion.outputs, "disabled_bench")

        let driving = try DORMEJSON.decoder.decode(RobotState.self, from: data("state_driving.json"))
        XCTAssertEqual(driving.motion.state, "moving")
        XCTAssertEqual(driving.motion.direction, "F")
        XCTAssertNotNil(driving.motion.owner)

        let lost = try DORMEJSON.decoder.decode(RobotState.self, from: data("state_link_lost.json"))
        XCTAssertEqual(lost.connection.esp32, "lost")
        XCTAssertEqual(lost.fault.active?.code, "LINK_LOST")
        XCTAssertNil(lost.battery.voltageV)
        XCTAssertNotNil(lost.battery.voltageReason)

        let low = try DORMEJSON.decoder.decode(RobotState.self, from: data("state_low_battery_no_camera.json"))
        XCTAssertEqual(low.battery.low, true)
        XCTAssertEqual(low.peripherals.camera.status, "unavailable")

        let running = try DORMEJSON.decoder.decode(RobotState.self, from: data("state_task_running.json"))
        XCTAssertEqual(running.task?.state, .running)
        XCTAssertNotNil(running.task?.progress)

        let jam = try DORMEJSON.decoder.decode(RobotState.self, from: data("state_fault_jam.json"))
        XCTAssertEqual(jam.fault.active?.code, "JAM")
        XCTAssertEqual(jam.fault.active?.phoneCanClear, true)
    }

    func testCapabilitiesAcksEvents() throws {
        let caps = try DORMEJSON.decoder.decode(Capabilities.self, from: data("capabilities.json"))
        XCTAssertEqual(caps.apiVersion, 1)
        XCTAssertFalse(caps.battery.percent)
        XCTAssertEqual(caps.drive.holdLeaseMs, 500)
        XCTAssertTrue(caps.tasks.contains { $0.action == "go_to_desk" && !$0.available })

        let acks = try DORMEJSON.decoder.decode([Ack].self, from: data("acks.json"))
        XCTAssertTrue(acks.contains { $0.code == "STALE" })
        XCTAssertNotNil(acks.first { $0.ok && $0.result.lookup("claim") != nil })

        let events = try JSONSerialization.jsonObject(with: data("events.json")) as! [[String: Any]]
        for raw in events {
            let d = try JSONSerialization.data(withJSONObject: raw)
            guard case .event(let ev) = try ServerMessage.decode(d) else { return XCTFail("not an event") }
            XCTAssertFalse(ev.kind.isEmpty)
        }
    }

    func testCommandWireFormatMatchesFixtures() throws {
        let examples = try JSONSerialization.jsonObject(with: data("commands.json")) as! [[String: Any]]
        let names = Set(examples.compactMap { $0["name"] as? String })
        let ours: [RobotCommand] = [.stop(), .claim(), .hold(claim: "x", direction: .forward, seq: 1), .release(claim: "x"),
                                    .startTask("greet"), .cancelTask("t"), .rearm(), .init("state.get"), .init("capabilities.get")]
        XCTAssertEqual(Set(ours.map(\.name)), names)
        let wire = try JSONSerialization.jsonObject(with: RobotCommand.hold(claim: "c", direction: .left, seq: 3).wireData()) as! [String: Any]
        XCTAssertEqual(wire["type"] as? String, "command")
        let args = wire["args"] as! [String: Any]
        XCTAssertEqual(args["direction"] as? String, "L")
        XCTAssertEqual(args["seq"] as? Int, 3)
        let cancel = try JSONSerialization.jsonObject(with: RobotCommand.cancelTask("t-1").wireData()) as! [String: Any]
        XCTAssertNotNil((cancel["args"] as! [String: Any])["task_id"], "snake_case kept on the wire")
    }
}
