import XCTest
@testable import DORMEKit

/// Demo robot rules, freshness and hold-to-drive. NOT YET RUN: needs a Mac (`swift test`).
@MainActor
final class BehaviourTests: XCTestCase {
    func connectedDemo() async -> (DemoRobot, Box) {
        let demo = DemoRobot()
        let box = Box()
        demo.onEvent = { box.events.append($0) }
        await demo.connect()
        return (demo, box)
    }

    final class Box { var events: [ClientEvent] = [] }

    func testDemoIsAlwaysLabelledSimulated() async {
        let (demo, _) = await connectedDemo()
        let s = demo.makeState()
        XCTAssertEqual(s.robot.mode, "demo")
        XCTAssertTrue(s.robot.simulated)
        XCTAssertTrue(s.battery.simulated)
        XCTAssertNil(s.battery.percent)
        XCTAssertTrue(demo.isDemo)
    }

    func testStopCancelsTaskAndInvalidatesClaim() async {
        let (demo, _) = await connectedDemo()
        let claim = await demo.send(.claim()).result.lookup("claim")!.string!
        let h1 = await demo.send(.hold(claim: claim, direction: .forward, seq: 1))
        XCTAssertTrue(h1.ok)
        let stop = await demo.stop()
        XCTAssertTrue(stop.ok)
        let late = await demo.send(.hold(claim: claim, direction: .forward, seq: 2))
        XCTAssertEqual(late.code, "STALE")
        let r1 = await demo.send(.startTask("self_check"))
        XCTAssertTrue(r1.ok)
        _ = await demo.stop()
        XCTAssertEqual(demo.makeState().task?.state, .cancelled)
    }

    func testLeaseExpiresWithoutHolds() async throws {
        let (demo, _) = await connectedDemo()
        let claim = await demo.send(.claim()).result.lookup("claim")!.string!
        _ = await demo.send(.hold(claim: claim, direction: .forward, seq: 1))
        XCTAssertEqual(demo.makeState().motion.state, "moving")
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(demo.makeState().motion.state, "stopped")
        let h2 = await demo.send(.hold(claim: claim, direction: .forward, seq: 2))
        XCTAssertEqual(h2.code, "STALE")
    }

    func testOneTaskAtATimeAndUnavailableReasons() async {
        let (demo, _) = await connectedDemo()
        let r4 = await demo.send(.startTask("go_to_desk"))      // no task running yet
        XCTAssertEqual(r4.code, "UNAVAILABLE")
        let r2 = await demo.send(.startTask("greet"))
        XCTAssertTrue(r2.ok)
        let r3 = await demo.send(.startTask("self_check"))
        XCTAssertEqual(r3.code, "TASK_ACTIVE")
        demo.setCameraAvailable(false)
        _ = await demo.send(.cancelTask(nil))
        let r5 = await demo.send(.startTask("take_photo"))
        XCTAssertEqual(r5.code, "UNAVAILABLE")
    }

    func testFaultBlocksDrivingUntilConfirmedRearm() async {
        let (demo, _) = await connectedDemo()
        demo.injectFault("STALE")
        let r6 = await demo.send(.claim())
        XCTAssertEqual(r6.code, "FAULT")
        let r7 = await demo.send(.init("fault.rearm"))
        XCTAssertEqual(r7.code, "CONFIRM_REQUIRED")
        let r8 = await demo.send(.rearm())
        XCTAssertTrue(r8.ok)
        let r9 = await demo.send(.claim())
        XCTAssertTrue(r9.ok)
        demo.injectFault("RAIL_LIVE")
        let r10 = await demo.send(.rearm())
        XCTAssertEqual(r10.code, "REARM_REFUSED")
    }

    func testDisconnectNeverResumesMotion() async {
        let (demo, _) = await connectedDemo()
        let claim = await demo.send(.claim()).result.lookup("claim")!.string!
        _ = await demo.send(.hold(claim: claim, direction: .forward, seq: 1))
        demo.simulateDisconnect(seconds: 0.2)
        let h2 = await demo.send(.hold(claim: claim, direction: .forward, seq: 2))
        XCTAssertEqual(h2.code, "OFFLINE")
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(demo.makeState().motion.state, "stopped")
        let h3 = await demo.send(.hold(claim: claim, direction: .forward, seq: 3))
        XCTAssertEqual(h3.code, "STALE")
    }

    func testControllerLinkLostWarnsThatStopCannotReachWheels() async {
        let (demo, _) = await connectedDemo()
        demo.setControllerLinked(false)
        let s = demo.makeState()
        XCTAssertEqual(s.fault.active?.code, "LINK_LOST")
        XCTAssertNil(s.battery.voltageV)
        let stop = await demo.stop()
        XCTAssertNotNil(stop.result.lookup("warning")?.string)
    }

    func testFreshnessPolicy() {
        let p = FreshnessPolicy()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(p.evaluate(lastMessage: nil, now: t0), .waiting)
        XCTAssertEqual(p.evaluate(lastMessage: t0, now: t0.addingTimeInterval(1)), .live)
        XCTAssertEqual(p.evaluate(lastMessage: t0, now: t0.addingTimeInterval(4)), .stale(age: 4))
        XCTAssertEqual(p.evaluate(lastMessage: t0, now: t0.addingTimeInterval(11)), .offline(lastSeen: t0))
        XCTAssertEqual(p.evaluate(lastMessage: t0, now: t0, socketOpen: false), .offline(lastSeen: t0))
    }

    func testDriveSessionStopsSendingOnRelease() async throws {
        let (demo, _) = await connectedDemo()
        let session = DriveSession(intervalMs: 100) { await demo.send($0) }
        session.press(.forward)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(session.activeDirection, .forward)
        XCTAssertEqual(demo.makeState().motion.state, "moving")
        let sent = session.holdsSent
        session.release()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(session.holdsSent, sent)
        XCTAssertEqual(demo.makeState().motion.state, "stopped")
    }

    func testDriveSessionReportsRefusal() async throws {
        let (demo, _) = await connectedDemo()
        demo.injectFault("JAM")
        let session = DriveSession(intervalMs: 100) { await demo.send($0) }
        session.press(.back)
        try await Task.sleep(nanoseconds: 200_000_000)
        guard case .refused(let code, _) = session.status else { return XCTFail("expected refusal") }
        XCTAssertEqual(code, "FAULT")
    }
}
