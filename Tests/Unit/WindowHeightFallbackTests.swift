import AppKit
import ApplicationServices
import Synchronization
import XCTest

@MainActor
final class WindowHeightFallbackTests: XCTestCase {
    private static let display = WindowAdjustmentDisplay(
        frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrame: CGRect(x: 0, y: 39, width: 1800, height: 1130),
        panelFrame: CGRect(x: 0, y: 1137, width: 1800, height: 32), displayUUID: "left")
    private static let full = CGRect(x: 0, y: 39, width: 1800, height: 1130)
    private static let clear = CGRect(x: 0, y: 39, width: 1800, height: 1098)
    private static let shifted = CGRect(x: 80, y: 71, width: 700, height: 1098)

    private final class Clock: Sendable {
        private struct Delivery: Sendable {
            let queue: DispatchQueue
            let fire: @Sendable () -> Void
        }

        private let delivery = Mutex<Delivery?>(nil)
        let installs = Mutex(0)

        func install(queue: DispatchQueue, fire: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
            installs.withLock { $0 += 1 }
            delivery.withLock { $0 = Delivery(queue: queue, fire: fire) }
            return { [self] in delivery.withLock { $0 = nil } }
        }

        func tick() async {
            guard let delivery = delivery.withLock({ $0 }) else { return }
            await withCheckedContinuation { continuation in
                delivery.queue.async {
                    delivery.fire()
                    continuation.resume()
                }
            }
        }
    }

    private struct Inputs: Sendable {
        var context: WindowHeightFallbackContext?
        var rows: [WindowHeightScanRow]? = []
        var snapshots = 0
        var frameReads = 0
        var resolutions: [CGWindowID] = []
        var nextRead: (@Sendable () -> Void)?
        var reuseFirst = false
        var knownPositionElement: AXElementKey?
        var membershipRevision: UInt64?
        var nextIdentityCheck: (@Sendable () -> Void)?
    }

    private final class InputStore: Sendable {
        private let state: Mutex<Inputs>

        init(_ inputs: Inputs) { state = Mutex(inputs) }

        func withLock<Value>(_ body: (inout Inputs) -> Value) -> Value {
            state.withLock { body(&$0) }
        }
    }

    @MainActor
    private final class Fixture {
        let desktop: BehaviorDesktop
        let inputs: InputStore
        let clock = Clock()
        let controller: WindowHeightFallback

        init(desktop: BehaviorDesktop = BehaviorDesktop(),
             readOverride: (@Sendable (AXElementKey) -> CGRect?)? = nil,
             writeOverride: (@Sendable (HeightWriteAction, AXElementKey) -> AXError)? = nil,
             startImmediately: Bool = true,
             displays: [WindowAdjustmentDisplay] = [WindowHeightFallbackTests.display],
             replacement: AXElementKey = AXElementKey(e: AXUIElementCreateApplication(-40999)),
             membership: (@Sendable (HeightFallbackProof, String, Int) -> Bool?)? = nil,
             readNativeDesktop: @escaping @Sendable (HeightFallbackProof, Int) -> Bool? = { _, _ in nil }) {
            self.desktop = desktop
            let desktopIDs = Dictionary(uniqueKeysWithValues: displays.compactMap(\.displayUUID).map { ($0, 1) })
            let context = WindowHeightFallbackContext(epoch: 1, displays: displays, desktopIDs: desktopIDs)
            let inputs = InputStore(Inputs(context: context))
            self.inputs = inputs
            let reader = AXWindowReader(accessibility: desktop)
            let read: @Sendable (AXElementKey) -> CGRect? = readOverride ?? { element in
                let frame = desktop.heightCommitFrame(element)
                let hook = inputs.withLock { state in
                    state.frameReads += 1
                    defer { state.nextRead = nil }
                    return state.nextRead
                }
                hook?()
                return frame
            }
            let write: @Sendable (HeightWriteAction, AXElementKey) -> AXError = writeOverride ?? { action, element in
                switch action {
                case .size(let size): reader.writeWindowSize(size, to: element.e)
                case .position(let point): reader.writeWindowPosition(point, to: element.e)
                }
            }
            controller = WindowHeightFallback(readFrame: read, write: write, capture: {
                inputs.withLock { state in
                    state.snapshots += 1
                    return state.rows
                }
            }, context: {
                inputs.withLock { $0.context }
            }, resolve: { row, context in
                let replaced = inputs.withLock { state in
                    state.resolutions.append(row.windowID)
                    return state.reuseFirst && row.windowID == 1001
                }
                guard let element = desktop.elements[row.windowID], let generation = desktop.generation(row.pid)
                else { return .unknown }
                return .ready(HeightFallbackProof(
                    key: HeightWriteKey(pid: row.pid, generation: generation, windowID: row.windowID),
                    element: replaced ? replacement : AXElementKey(e: element), context: context))
            }, isCurrent: { proof in
                let hook = inputs.withLock { state in
                    defer { state.nextIdentityCheck = nil }
                    return state.nextIdentityCheck
                }
                hook?()
                if inputs.withLock({ $0.reuseFirst }), proof.key.windowID == 1001 { return proof.element == replacement }
                return desktop.generation(proof.key.pid) == proof.key.generation
            }, isCurrentPosition: { proof in
                inputs.withLock { $0.knownPositionElement.map { $0 == proof.element } ?? true }
            }, membership: { proof, uuid, desktop in
                inputs.withLock { state in
                    let matches = state.knownPositionElement.map { $0 == proof.element } ?? true
                    let confirmed: Bool?
                    if !matches {
                        confirmed = false
                    } else if let membership {
                        confirmed = membership(proof, uuid, desktop)
                    } else {
                        confirmed = state.context?.desktopIDs[uuid] == desktop
                    }
                    return HeightFallbackMembership(confirmed: confirmed, revision: state.membershipRevision)
                }
            }, readNativeDesktop: readNativeDesktop, schedule: clock.install)
            if startImmediately { controller.start() }
        }

        func frames(_ entries: [(CGWindowID, CGRect, CGRect)]) {
            desktop.state.withLock { state in
                for (id, _, ax) in entries { state.windows[id]?.bounds = ax }
            }
            inputs.withLock {
                $0.rows = entries.map { id, cg, _ in
                    WindowHeightScanRow(windowID: id, pid: -41000, layer: 0, bounds: cg)
                }
            }
        }

        func tick(_ count: Int = 1) async {
            for _ in 0..<count {
                await clock.tick()
                await controller.drainForTesting()
            }
        }

        var sizes: [CGSize] { desktop.state.withLock { $0.requestedSizes } }
        var positions: [CGPoint] { desktop.state.withLock { $0.requestedPositions } }
    }

    func testPollGeometry() async {
        let fixture = Fixture()
        defer { fixture.controller.stop() }
        let shifted = CGRect(x: 80, y: 71, width: 700, height: 1110)
        fixture.frames([(1001, shifted, shifted)])
        await fixture.tick()
        XCTAssertEqual(fixture.positions, [CGPoint(x: 80, y: 39)])
        let correctedTop = CGRect(x: 80, y: 39, width: 700, height: 1110)
        fixture.frames([(1001, correctedTop, correctedTop)])
        await fixture.tick()
        XCTAssertEqual(fixture.sizes, [CGSize(width: 700, height: 1098)])
        for top in [40, 70, 72] {
            let other = CGRect(x: 80, y: top, width: 700, height: 1100)
            fixture.frames([(1001, other, other)])
            await fixture.tick()
        }
        let touching = CGRect(x: 110, y: 39, width: 600, height: 1098)
        fixture.frames([(1001, touching, touching)])
        await fixture.tick()
        XCTAssertEqual(fixture.positions.count, 1)
        XCTAssertEqual(fixture.sizes.count, 1)
    }

    func testPollRechecksOnEveryTick() async {
        let fixture = Fixture()
        defer { fixture.controller.stop() }
        fixture.desktop.state.withLock { $0.rejectSizeAsUnsupported = true }
        let both: [(CGWindowID, CGRect, CGRect)] = [(1001, Self.full, Self.full), (1002, Self.full, Self.full)]
        fixture.frames(both)
        await fixture.tick()
        XCTAssertEqual(fixture.sizes.count, 2)
        await fixture.tick(20)
        XCTAssertEqual(fixture.sizes.count, 42)
        let reads = fixture.inputs.withLock { $0.frameReads }
        fixture.frames([(1001, Self.clear, Self.full)])
        await fixture.tick(25)
        XCTAssertEqual(fixture.sizes.count, 42)
        XCTAssertEqual(fixture.inputs.withLock { $0.frameReads }, reads)
    }

    func testPollUsesLatestProof() async {
        let fixture = Fixture()
        defer { fixture.controller.stop() }
        let entered = expectation(description: "First AX read held")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        fixture.inputs.withLock {
            $0.nextRead = {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 2)
            }
        }
        fixture.frames([(1001, Self.full, Self.clear), (1002, Self.full, Self.full)])
        await fixture.clock.tick()
        await fulfillment(of: [entered], timeout: 1)
        fixture.frames([(1001, Self.full, Self.clear), (1002, Self.full, Self.full)])
        await fixture.clock.tick()
        release.signal()
        await fixture.controller.drainForTesting()
        let attempts = fixture.desktop.state.withLock { $0.writes }
        XCTAssertEqual(attempts, ["1002:AXSize"])
    }

    func testSnapshotArrivingDuringSetterReconsidersWindowAfterItsPeer() async throws {
        let desktop = BehaviorDesktop()
        let first = AXElementKey(e: try XCTUnwrap(desktop.elements[1001]))
        let second = AXElementKey(e: try XCTUnwrap(desktop.elements[1002]))
        let entered = expectation(description: "First setter")
        let release = DispatchSemaphore(value: 0)
        let writes = Mutex<[AXElementKey]>([])
        let fixture = Fixture(desktop: desktop, writeOverride: { _, element in
            let index = writes.withLock { values in
                values.append(element)
                return values.count
            }
            if index == 1 {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 2)
            }
            return .cannotComplete
        })
        defer { release.signal(); fixture.controller.stop() }
        fixture.frames([(1001, Self.full, Self.full), (1002, Self.full, Self.full)])
        await fixture.clock.tick()
        await fulfillment(of: [entered], timeout: 1)
        await fixture.clock.tick()
        release.signal()
        await fixture.controller.drainForTesting()
        XCTAssertEqual(writes.withLock { $0 }, [first, second, first])
        XCTAssertEqual(fixture.inputs.withLock { $0.snapshots }, 2)
    }

    func testMovingWindowOffDesktopDuringAXReadRefusesTheWrite() async {
        let membership = Mutex<Bool?>(true)
        let fixture = Fixture(membership: { _, _, _ in membership.withLock { $0 } })
        defer { fixture.controller.stop() }
        fixture.frames([(1001, Self.full, Self.full)])
        fixture.inputs.withLock { $0.nextRead = { membership.withLock { $0 = false } } }
        await fixture.tick()
        XCTAssertTrue(fixture.sizes.isEmpty)
        membership.withLock { $0 = true }
        await fixture.tick()
        XCTAssertEqual(fixture.sizes, [Self.clear.size])
    }

    func testRevokedMembershipDuringAXReadDoesNotRepeatNativeSpaceRead() async {
        let lookups = Mutex(0)
        let fixture = Fixture(membership: { _, _, _ in nil }, readNativeDesktop: { _, _ in
            lookups.withLock { $0 += 1 }
            return true
        })
        defer { fixture.controller.stop() }
        fixture.frames([(1001, Self.full, Self.full)])
        let inputs = fixture.inputs
        inputs.withLock { $0.nextRead = { inputs.withLock { $0.membershipRevision = 2 } } }
        await fixture.tick()
        XCTAssertTrue(fixture.sizes.isEmpty)
        XCTAssertEqual(lookups.withLock { $0 }, 1)
        await fixture.tick()
        XCTAssertEqual(fixture.sizes, [Self.clear.size])
        XCTAssertEqual(lookups.withLock { $0 }, 2)
    }

    func testNativeAdmissionKeepsExactIdentityAndDesktopDecision() throws {
        let desktop = BehaviorDesktop()
        let source = try XCTUnwrap(desktop.state.withLock { $0.windows[1001] })
        let identity = try XCTUnwrap(WindowSpaceIdentity(source.actionIdentity))
        let element = AXElementKey(e: try XCTUnwrap(desktop.elements[1001]))
        let replacement = AXElementKey(e: AXUIElementCreateApplication(-81001))
        let liveElement = Mutex(element)
        let confirmed = Mutex<Bool?>(false)
        let nativeReads = Mutex(0)
        let resolver = NativeHeightFallbackResolver(accessibility: desktop, system: desktop, inventory: { _ in
            .ordinary(identity, liveElement.withLock { $0 })
        }, confirmedDesktop: { _, _, _, _ in HeightFallbackMembership(confirmed: confirmed.withLock { $0 }) },
            spaceIDs: { _ in
            nativeReads.withLock { $0 += 1 }
            liveElement.withLock { $0 = replacement }
            return [1]
        })
        let context = WindowHeightFallbackContext(epoch: 1, displays: [Self.display], desktopIDs: ["left": 1])
        guard case .ready(let proof) = resolver.resolve(
            WindowHeightScanRow(windowID: 1001, pid: -41000, layer: 0, bounds: Self.full), context: context
        ) else { return XCTFail("The injected native owner and exact inventory element should be admitted") }
        XCTAssertFalse(resolver.membership(proof, display: "left", desktop: 1)
            .permits(using: { resolver.readNativeDesktop(proof, desktop: 1) }))
        XCTAssertEqual(nativeReads.withLock { $0 }, 0)
        confirmed.withLock { $0 = nil }
        XCTAssertTrue(resolver.membership(proof, display: "left", desktop: 1)
            .permits(using: { resolver.readNativeDesktop(proof, desktop: 1) }))
        XCTAssertFalse(resolver.isCurrent(proof))
        XCTAssertEqual(nativeReads.withLock { $0 }, 1)
    }

    func testRuntimeHasOneAdjustmentTrigger() async {
        let fixture = Fixture(startImmediately: false)
        let runtime = AppRuntime(tracker: BehaviorInventory(fixture.desktop))
        let topology = DisplayTopologyStore(initialSnapshot: .init(
            physicalDisplayCount: 0, identifiedDisplayUUIDs: [], attributionTable: .empty))
        let orchestrator = TaskbarScreenOrchestrator(runtime: runtime, stripOrderStore: StripOrderStore(),
            displayTopologyStore: topology,
            topologySnapshotProvider: { .init(physicalDisplayCount: 0, identifiedDisplayUUIDs: [], attributionTable: .empty) },
            windowAdjustmentEnabled: true, makeHeightPoller: { _ in fixture.controller })
        defer { orchestrator.suspendAndRelease(); runtime.stop() }
        fixture.frames([(1001, Self.full, Self.full)])
        runtime.start()
        orchestrator.start()
        orchestrator.start()
        XCTAssertEqual(fixture.clock.installs.withLock { $0 }, 1)
        runtime.refreshFrontmostWindow()
        await fixture.controller.drainForTesting()
        XCTAssertTrue(fixture.sizes.isEmpty)
        await fixture.tick()
        XCTAssertEqual(fixture.sizes, [Self.clear.size])
        orchestrator.stopWindowHeightPolling()
        fixture.frames([(1001, Self.full, Self.full)])
        await fixture.tick()
        XCTAssertEqual(fixture.sizes.count, 1)
    }

    static func verifyQuitKeepsCorrectedHeight() async {
        let display = WindowAdjustmentDisplay(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 30, width: 1920, height: 1050),
            panelFrame: CGRect(x: 0, y: 1048, width: 1920, height: 32), displayUUID: "left")
        let height = Fixture(startImmediately: false, displays: [display])
        let frame = CGRect(x: 200, y: 30, width: 700, height: 1050)
        let fixture = ApplicationBehaviorTests.Fixture(trusted: true, configureEnvironment: { environment, _ in
            environment.makePanels = { runtime, order, topology in
                TaskbarScreenOrchestrator(runtime: runtime, stripOrderStore: order, displayTopologyStore: topology,
                    topologySnapshotProvider: { .init(physicalDisplayCount: 0, identifiedDisplayUUIDs: [], attributionTable: .empty) },
                    windowAdjustmentEnabled: true, makeHeightPoller: { _ in height.controller })
            }
        })
        defer { fixture.stop() }
        height.frames([(1001, frame, frame)])
        fixture.launch()
        await height.tick()
        XCTAssertEqual(height.sizes, [CGSize(width: 700, height: 1018)])
        XCTAssertEqual(fixture.delegate.applicationShouldTerminate(NSApplication.shared), NSApplication.TerminateReply.terminateNow)
        await height.tick()
        XCTAssertEqual(height.sizes, [CGSize(width: 700, height: 1018)])
        XCTAssertEqual(height.desktop.state.withLock { $0.windows[1001]?.bounds },
                       CGRect(x: 200, y: 30, width: 700, height: 1018))
    }

    static func verifyCaptureDuringHeldAX(
        access: RuntimeAccessibilityAccess, during block: @MainActor () async -> Void
    ) async {
        let desktop = BehaviorDesktop()
        let axEntered = Mutex(false)
        let axRelease = DispatchSemaphore(value: 0)
        let fixture = Fixture(desktop: desktop, readOverride: { element in
            axEntered.withLock { $0 = true }
            _ = axRelease.wait(timeout: .now() + 2)
            return desktop.heightCommitFrame(element)
        }, writeOverride: { _, _ in
            access.call {
                XCTFail("A held AX correction must not reach the setter after loss")
                return .success
            }
        })
        defer { axRelease.signal(); fixture.controller.stop() }
        fixture.frames([(1001, Self.full, Self.full)])
        await fixture.clock.tick()
        let deadline = ContinuousClock.now + .seconds(1)
        while !axEntered.withLock({ $0 }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(axEntered.withLock { $0 })
        XCTAssertEqual(fixture.inputs.withLock { $0.snapshots }, 1)
        await block()
        axRelease.signal()
        await fixture.controller.drainForTesting()
    }

    func testPanelRestoredAfterStaleAdmissionIsRecheckedOnNextTick() async {
        let fixture = Fixture()
        defer { fixture.controller.stop() }
        fixture.frames([(1001, Self.full, Self.full)])
        let missingPanel = WindowAdjustmentDisplay(
            frame: Self.display.frame, visibleFrame: Self.display.visibleFrame, panelFrame: nil, displayUUID: "left"
        )
        let inputs = fixture.inputs
        inputs.withLock { $0.nextRead = { inputs.withLock { $0.context?.displays = [missingPanel] } } }
        await fixture.tick()
        XCTAssertEqual(fixture.sizes, [])
        inputs.withLock { $0.context?.displays = [Self.display] }
        await fixture.tick()
        XCTAssertEqual(fixture.sizes, [Self.clear.size])
    }

    func testFallbackRaisesExactShiftWithoutChangingWidthOrX() async {
        let largerPanel = WindowAdjustmentDisplay(
            frame: Self.display.frame, visibleFrame: Self.display.visibleFrame,
            panelFrame: CGRect(x: 0, y: 1105, width: 1800, height: 64), displayUUID: "left"
        )
        for (display, cg) in [(Self.display, Self.shifted),
                              (largerPanel, CGRect(x: 80, y: 103, width: 700, height: 1066))] {
            let fixture = Fixture(displays: [display])
            defer { fixture.controller.stop() }
            let ax = CGRect(x: 120, y: cg.minY, width: 600, height: cg.height)
            fixture.frames([(1001, cg, ax)])
            await fixture.tick()
            XCTAssertEqual(fixture.positions, [CGPoint(x: 120, y: 39)])
            XCTAssertTrue(fixture.sizes.isEmpty)
            XCTAssertEqual(fixture.inputs.withLock { $0.frameReads }, 1)
            XCTAssertEqual(fixture.desktop.state.withLock { $0.windows[1001]?.bounds },
                           CGRect(x: 120, y: 39, width: 600, height: cg.height))
        }
    }

    func testFallbackRejectsNearShiftAndStaleShift() async {
        let right = WindowAdjustmentDisplay(
            frame: Self.display.frame.offsetBy(dx: 1800, dy: 0),
            visibleFrame: Self.display.visibleFrame.offsetBy(dx: 1800, dy: 0),
            panelFrame: Self.display.panelFrame?.offsetBy(dx: 1800, dy: 0), displayUUID: "right"
        )
        let near = Self.shifted.offsetBy(dx: 0, dy: 1)
        for scenario in [0, 1, 3, 4] {
            let fixture = Fixture(displays: [Self.display, right])
            defer { fixture.controller.stop() }
            let cg = scenario == 0 ? near : Self.shifted
            let ax: CGRect
            switch scenario {
            case 1: ax = near
            case 3: ax = cg.offsetBy(dx: 1800, dy: 0)
            default: ax = cg
            }
            fixture.frames([(1001, cg, ax)])
            let inputs = fixture.inputs
            if scenario == 4 {
                inputs.withLock { $0.nextRead = { inputs.withLock { $0.context?.desktopIDs["left"] = 2 } } }
            }
            await fixture.tick(scenario == 4 ? 1 : 26)
            XCTAssertTrue(fixture.positions.isEmpty, "scenario \(scenario)")
            XCTAssertTrue(fixture.sizes.isEmpty, "scenario \(scenario)")
        }
    }

    func testSizeUnsupportedDoesNotBlockFallbackPosition() async {
        let fixture = Fixture()
        defer { fixture.controller.stop() }
        fixture.desktop.state.withLock { $0.rejectSizeAsUnsupported = true }
        fixture.frames([(1001, Self.full, Self.full)])
        await fixture.tick()
        XCTAssertEqual(fixture.sizes, [Self.clear.size])
        fixture.frames([(1001, Self.shifted, Self.shifted)])
        await fixture.tick()
        XCTAssertEqual(fixture.positions, [CGPoint(x: 80, y: 39)])
    }

    func testFallbackPositionRejectsKnownReplacementWithSameCGID() async {
        let fixture = Fixture()
        defer { fixture.controller.stop() }
        let replacement = AXElementKey(e: AXUIElementCreateApplication(-40999))
        let inputs = fixture.inputs
        inputs.withLock { $0.nextRead = { inputs.withLock { $0.knownPositionElement = replacement } } }
        fixture.frames([(1001, Self.shifted, Self.shifted)])
        await fixture.tick()
        XCTAssertEqual(fixture.inputs.withLock { $0.resolutions }, [1001])
        XCTAssertTrue(fixture.positions.isEmpty)
    }

    func testFallbackPositionRejectsReplacementDuringFinalIdentityCheck() async {
        let fixture = Fixture()
        defer { fixture.controller.stop() }
        let replacement = AXElementKey(e: AXUIElementCreateApplication(-40999))
        let inputs = fixture.inputs
        inputs.withLock {
            $0.nextRead = {
                inputs.withLock { $0.nextIdentityCheck = { inputs.withLock { $0.knownPositionElement = replacement } } }
            }
        }
        fixture.frames([(1001, Self.shifted, Self.shifted)])
        await fixture.tick()
        XCTAssertEqual(fixture.inputs.withLock { $0.frameReads }, 1)
        XCTAssertTrue(fixture.positions.isEmpty)
    }

    func testNativePositionIdentityRejectsKnownOffDesktopAndMinimizedBindings() throws {
        let desktop = BehaviorDesktop()
        let existing = try XCTUnwrap(desktop.state.withLock { $0.windows[1001] })
        let element = AXElementKey(e: try XCTUnwrap(desktop.elements[1001]))
        let replacement = AXElementKey(e: AXUIElementCreateApplication(-40999))
        let generation = try XCTUnwrap(desktop.generation(existing.pid))
        let key = HeightWriteKey(pid: existing.pid, generation: generation, windowID: 1001)
        let context = WindowHeightFallbackContext(epoch: 1, displays: [Self.display],
                                                  desktopIDs: ["left": 1])
        let proof = HeightFallbackProof(key: key, element: element, context: context)
        func record(element: AXElementKey, onDesktop: Bool, status: WindowStatus = .inactive) -> WindowRecord {
            WindowRecord(id: existing.id, appID: existing.appID, pid: existing.pid,
                bundleIdentifier: existing.bundleIdentifier, title: existing.title, bounds: Self.shifted,
                status: status, cgWindowID: key.windowID, isOnDesktop: onDesktop,
                processGeneration: generation, actionTarget: WindowActionTarget(element: element))
        }
        let records = Mutex([record(element: element, onDesktop: true)])
        let resolver = NativeHeightFallbackResolver(accessibility: desktop, system: desktop,
            inventory: { key in records.withLock { HeightFallbackInventory.classify(key, in: $0) } },
            confirmedDesktop: { _, _, _, _ in HeightFallbackMembership(confirmed: false) })
        XCTAssertTrue(resolver.isCurrentPosition(proof))
        let offDesktop = record(element: replacement, onDesktop: false)
        records.withLock { $0 = [offDesktop] }
        XCTAssertFalse(resolver.isCurrentPosition(proof))
        let minimized = record(element: element, onDesktop: true, status: .minimized)
        records.withLock { $0 = [minimized] }
        XCTAssertFalse(resolver.isCurrentPosition(proof))
        records.withLock { $0.removeAll() }
        XCTAssertTrue(resolver.isCurrentPosition(proof))
    }

    func testIdlePassUsesOneSnapshotAndZeroAX() async {
        let fixture = Fixture()
        defer { fixture.controller.stop() }
        fixture.inputs.withLock {
            $0.rows = [WindowHeightScanRow(windowID: 0, pid: -41000, layer: 0, bounds: Self.full)]
        }
        await fixture.tick()
        XCTAssertEqual(fixture.inputs.withLock { $0.snapshots }, 1)
        XCTAssertEqual(fixture.inputs.withLock { $0.resolutions }, [])
        fixture.inputs.withLock { $0.context = nil }
        await fixture.tick()
        XCTAssertEqual(fixture.inputs.withLock { $0.snapshots }, 1)
        XCTAssertEqual(fixture.inputs.withLock { $0.resolutions }, [])
    }

    func testNativeOverwriteAfterSuccessIsRediscovered() async {
        for sampledClear in [false, true] {
            let fixture = Fixture()
            defer { fixture.controller.stop() }
            fixture.frames([(1001, Self.full, Self.full)])
            await fixture.tick()
            XCTAssertEqual(fixture.sizes, [Self.clear.size])
            fixture.frames([(1001, sampledClear ? Self.clear : Self.full, sampledClear ? Self.clear : Self.full)])
            await fixture.tick()
            XCTAssertEqual(fixture.sizes.count, sampledClear ? 1 : 2)
            fixture.frames([(1001, Self.full, Self.full)])
            await fixture.tick()
            XCTAssertEqual(fixture.sizes, Array(repeating: Self.clear.size, count: sampledClear ? 2 : 3))
        }
    }

    func testStaleScopeDoesNotWrite() async {
        for change in 0..<6 {
            let fixture = Fixture()
            defer { fixture.controller.stop() }
            let entered = expectation(description: "AX frame read")
            let release = DispatchSemaphore(value: 0)
            fixture.frames([(1001, Self.full, Self.full)])
            fixture.inputs.withLock { $0.nextRead = { entered.fulfill(); _ = release.wait(timeout: .now() + 3) } }
            await fixture.clock.tick()
            await fulfillment(of: [entered], timeout: 1)
            switch change {
            case 0:
                fixture.inputs.withLock { $0.context?.desktopIDs = ["left": 2] }
            case 1:
                fixture.inputs.withLock { $0.context?.displays[0] = WindowAdjustmentDisplay(
                    frame: Self.display.frame, visibleFrame: Self.display.visibleFrame, panelFrame: nil, displayUUID: "left") }
            case 2:
                fixture.inputs.withLock { $0.context?.displays[0] = WindowAdjustmentDisplay(
                    frame: Self.display.frame, visibleFrame: Self.display.visibleFrame.offsetBy(dx: 0, dy: 1),
                    panelFrame: Self.display.panelFrame, displayUUID: "left") }
            case 3:
                fixture.inputs.withLock { $0.context = nil }
            case 4:
                fixture.inputs.withLock { $0.reuseFirst = true }
            default:
                fixture.controller.stop()
            }
            release.signal()
            await fixture.controller.drainForTesting()
            XCTAssertEqual(fixture.sizes, [], "stale case \(change)")
        }
    }

}
