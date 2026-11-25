# DORM-E iPhone app (SwiftUI, iOS 17+)

**Status: source only. It has not been compiled.** It was written on Windows, where Xcode cannot run.
There is no TestFlight build. The first Mac build will likely need small compile fixes.

## Layout

| Path | What |
|---|---|
| `DORMEKit/` | Swift package, Foundation only: API v1 models, `RobotClient` protocol, isolated `DemoRobot`, `DriveSession` (hold-to-drive), `FreshnessPolicy`. Tests decode `../spec/fixtures` |
| `DORME/App` | `DORMEApp`, `RootView`, `RobotStore` (one client at a time: demo or Wi-Fi) |
| `DORME/Net` | `NetworkRobotClient` (HTTP + WebSocket, Keychain token), `MJPEGStream`, `BLEScanner` |
| `DORME/Screens` | Home, Control, Tasks, Robot, Connect + Demo scenarios |
| `DORME/UI` | Theme (warm white, soft gray cards, continuous corners), capsule tab bar, banners, face, camera |
| `project.yml` | XcodeGen project definition |

## Build on a Mac

```sh
cd dorme_platform/ios/DORMEKit && swift test          # package + fixture/demo/drive tests
cd .. && brew install xcodegen && xcodegen && open DORME.xcodeproj
```
In Xcode: set your Team under Signing, pick an iPhone simulator or your phone, Run.
Without XcodeGen: File > New > Project > iOS App "DORME" (SwiftUI), delete the template files, drag in
`DORME/`, add `DORMEKit` with File > Add Package Dependencies > Add Local, and use `DORME/Info.plist`.

## Launch the demo

Open the app. The Connect sheet appears: tap **Start demo**. Everything shown is simulated and labelled
"Demo". Tap **Scenarios** on the Demo banner for: low battery, camera unavailable, bench mode,
motor-controller link lost, a 14 s Wi-Fi drop (stale at 3 s, offline at 10 s, nothing resumes), a
clearable fault (STALE) and a service fault (RAIL_LIVE). Hold an arrow on Control to drive; lift to
stop; press Stop during any task to see it cancelled.

## Connect to the coordinator

Same Wi-Fi as the robot (or the PC running the simulator). Address `dorm-e.local` or an IP, port 8080,
then the PIN. The simulator prints its PIN in its console. Uses plain HTTP on the local network
(`NSAllowsLocalNetworking`); connecting by raw IP address under App Transport Security is untested.
