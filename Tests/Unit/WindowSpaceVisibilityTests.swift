import XCTest
import Synchronization

private func identity(_ itemID: String, pid: Int32, windowID: UInt32, targetID: UUID? = nil) -> WindowSpaceIdentity {
    WindowSpaceIdentity(.init(windowID: WindowID(rawValue: itemID), pid: pid, processGeneration: nil,
        cgWindowID: windowID, groupID: itemID, targetID: targetID))!
}

final class WindowSpaceVisibilityTests: XCTestCase {
    private let window = identity("browser", pid: 42, windowID: 100)
    private let other = identity("editor", pid: 43, windowID: 101)

    private func layout(_ current: Int, spaces: [Int] = [1, 2, 3], fullscreen: Set<Int> = [3]) -> SpaceLayoutSnapshot {
        SpaceLayoutSnapshot(orderedSpaceIDs: spaces, fullscreenSpaceIDs: fullscreen, currentSpaceID: current)
    }

    func testFallbackPrimaryUsesOnlyMainSpaceAndPhysicallyLocalUtilityWindows() throws {
        let external = WindowRecord(id: WindowID(rawValue: "external"), appID: AppID(rawValue: "external-app"),
            pid: 42, bundleIdentifier: nil, title: "External", bounds: nil, status: .active, cgWindowID: 125)
        let local = WindowRecord(id: WindowID(rawValue: "local"), appID: AppID(rawValue: "desk"),
            pid: 43, bundleIdentifier: nil, title: "Local", bounds: nil, status: .active,
            source: .utility(spaceWindowNumber: 126))
        let remote = WindowRecord(id: WindowID(rawValue: "remote"), appID: AppID(rawValue: "desk"),
            pid: 43, bundleIdentifier: nil, title: "Remote", bounds: nil, status: .active,
            source: .utility(spaceWindowNumber: 127))
        let externalItem = StripItem(record: external)
        let member = try XCTUnwrap(externalItem.spaceIdentity)
        let items = [externalItem, StripItem(record: local), StripItem(record: remote)]
        let filter = StripDisplayFilter(scope: nil, connectedUUIDs: [], primaryUUID: nil, physicalDisplayCount: 2)
        let spaces = WindowSpaceSnapshot(layouts: ["Main": layout(1), "other": layout(2)], memberships: [member: [2]])
        let visible = TaskbarPresentation.visibleItems(items, filter: filter, spaces: spaces,
            utilityOnPanelDisplay: { $0 == local.id }, utilityOnActiveSpace: { _ in true })
        XCTAssertEqual(Set(visible.keys), [local.groupID])
        let unplugged = StripDisplayFilter(scope: nil, connectedUUIDs: [], primaryUUID: nil, physicalDisplayCount: 1)
        let stale = WindowSpaceSnapshot(layouts: ["first": layout(1), "other": layout(2)], memberships: [member: [2]])
        XCTAssertTrue(TaskbarPresentation.visibleItems([externalItem], filter: unplugged, spaces: stale).isEmpty)
    }

    func testUtilityKeepsNewSpaceWhenMinimizedImmediatelyAfterConfirmedTransfer() {
        let visible = WindowSpaceRequest(identity: window, isParked: false, isOnDesktop: true,
                                         displayUUID: "left", isUtility: true)
        let parked = WindowSpaceRequest(identity: window, isParked: true, isOnDesktop: false,
                                        displayUUID: "left", isUtility: true)
        let initial = WindowSpaceSnapshot().updating(
            with: .init(layouts: ["left": layout(1)], memberships: [window: [1]]),
            requests: [visible])
        let newSpace = WindowSpaceSnapshot(layouts: ["left": layout(2)], memberships: [window: [2]])
        let moved = initial.updating(with: newSpace, requests: [visible], afterSpaceChange: true)
        let minimized = moved.updating(with: newSpace, requests: [parked])

        XCTAssertEqual(minimized.memberships[window], [2])
        XCTAssertTrue(minimized.shows(window, on: "left"))
    }

    func testParkedUtilityAcceptsMembershipOnTheRemainingSpaceAfterItsSpaceIsRemoved() {
        let visible = WindowSpaceRequest(identity: window, isParked: false, isOnDesktop: true,
                                         displayUUID: "left", isUtility: true)
        let parked = WindowSpaceRequest(identity: window, isParked: true, isOnDesktop: false,
                                        displayUUID: "left", isUtility: true)
        let initial = WindowSpaceSnapshot(layouts: ["left": layout(1)], memberships: [window: [1]])
        let shown = WindowSpaceSnapshot().updating(with: initial, requests: [visible])
        let minimized = shown.updating(with: initial, requests: [parked])
        let newLayout = WindowSpaceSnapshot(layouts: ["left": layout(2, spaces: [2], fullscreen: [])],
                                            memberships: [window: [2]])
        let moved = minimized.updating(with: newLayout, requests: [parked], afterSpaceChange: true)
        XCTAssertEqual(moved.memberships[window], [2])
        XCTAssertTrue(moved.shows(window, on: "left"))
    }

    func testUtilityAcceptsNewSpaceWhenItParksBeforeTheLayoutArrives() {
        let visible = WindowSpaceRequest(identity: window, isParked: false, isOnDesktop: true,
                                        displayUUID: "left", isUtility: true, isOnActiveSpace: true)
        let parked = WindowSpaceRequest(identity: window, isParked: true, isOnDesktop: false,
                                       displayUUID: "left", isUtility: true)
        let first = WindowSpaceSnapshot(layouts: ["left": layout(1)], memberships: [window: [1]])
        let shown = WindowSpaceSnapshot().updating(with: first, requests: [visible])
        let pending = shown.recordingSpaceChange(requests: [visible])
        let after = WindowSpaceSnapshot(layouts: ["left": layout(2)], memberships: [window: [2]])
        let result = pending.updating(with: after, requests: [parked], afterSpaceChange: true)
        XCTAssertEqual(result.memberships[window], [2])
        XCTAssertTrue(result.shows(window, on: "left"))
        let back = pending.recordingSpaceChange(requests: [parked])
        let oldSpaceAgain = WindowSpaceSnapshot(layouts: ["left": layout(1)], memberships: [window: [2]])
        let firstRead = back.updating(with: oldSpaceAgain, requests: [parked], afterSpaceChange: true)
        XCTAssertEqual(firstRead.memberships[window], [1])
        let confirmedRead = firstRead.updating(with: oldSpaceAgain, requests: [parked])
        XCTAssertEqual(confirmedRead.memberships[window], [2])
    }

    func testParkedUtilityMovesOffAConfirmedDisconnectedDisplay() {
        let visible = WindowSpaceRequest(identity: window, isParked: false, isOnDesktop: true,
                                        displayUUID: "right", isUtility: true, isOnActiveSpace: true)
        let parked = WindowSpaceRequest(identity: window, isParked: true, isOnDesktop: false,
                                       displayUUID: "right", isUtility: true)
        let first = WindowSpaceSnapshot(layouts: ["left": layout(1, spaces: [1]), "right": layout(2, spaces: [2])],
                                         memberships: [window: [2]])
        let shown = WindowSpaceSnapshot().updating(with: first, requests: [visible])
        let remaining = WindowSpaceSnapshot(layouts: ["left": layout(1, spaces: [1])], memberships: [window: [1]])
        let partial = shown.updating(with: remaining, requests: [parked], attachedDisplays: ["left", "right"])
        XCTAssertEqual(partial.memberships[window], [2])
        let detached = shown.updating(with: remaining, requests: [parked], attachedDisplays: ["left"])
        XCTAssertEqual(detached.memberships[window], [1])
        XCTAssertTrue(detached.shows(window, on: "left"))
    }

    func testCaptureStopsBetweenMembershipRequestsOnCancellationOrDeadline() {
        let requests = [window, other].map { WindowSpaceRequest(identity: $0, isParked: false, isOnDesktop: true) }
        let expectedLayout = ["left": layout(1)]
        for expires in [false, true] {
            let cancellation = OperationCancellation()
            let now = Mutex<TimeInterval>(100)
            var reads = 0
            let result = WindowSpaceObservation.capture(requests, cancellation: cancellation, maximumDuration: 1,
                uptime: { now.withLock { $0 } }, layouts: { expectedLayout }, membership: { _ in
                    reads += 1
                    if expires { now.withLock { $0 = 102 } } else { cancellation.cancel() }
                    return [1]
                })
            XCTAssertNil(result)
            XCTAssertEqual(reads, 1)
        }
    }

    func testCaptureSharesMembershipForRequestsWithTheSameWindowNumber() {
        let alternate = identity("alternate", pid: window.actionIdentity.pid, windowID: window.windowID)
        let requests = [window, alternate].map {
            WindowSpaceRequest(identity: $0, isParked: false, isOnDesktop: true)
        }
        var calls: [Int] = []
        let snapshot = WindowSpaceObservation.capture(
            requests, cancellation: OperationCancellation(), layouts: { ["left": layout(1)] }, membership: { number in
                calls.append(number)
                return [1, 2]
            }
        )
        XCTAssertEqual(calls, [Int(window.windowID)])
        XCTAssertEqual(snapshot?.memberships, [window: [1, 2], alternate: [1, 2]])
    }

    func testBatchMapsStickyWindowsAndFallsBackForParkedAndMissingWindows() {
        let sticky = window
        let regular = other
        let missing = identity("missing", pid: 43, windowID: 102)
        let parked = identity("parked", pid: 43, windowID: 103)
        let requests = [sticky, regular, missing, parked].map {
            WindowSpaceRequest(identity: $0, isParked: $0 == parked, isOnDesktop: $0 != parked)
        }
        var scalarReads: [Int] = []
        var spaceReads: [Int] = []
        let snapshot = WindowSpaceObservation.capture(
            requests, cancellation: OperationCancellation(),
            layouts: { ["left": layout(1, spaces: [1, 2], fullscreen: [])] },
            membership: { number in
                scalarReads.append(number)
                return number == 103 ? [2] : nil
            },
            mode: .batch, windowsInSpace: { space in
                spaceReads.append(space)
                return space == 1 ? [100, 101, 103] : [100]
            }
        )
        XCTAssertEqual(spaceReads, [1, 2])
        XCTAssertEqual(scalarReads, [102, 103])
        XCTAssertEqual(snapshot?.memberships, [sticky: [1, 2], regular: [1], parked: [2]])
    }

    func testBatchVerificationAndMissingSpaceResultKeepAuthoritativeValues() {
        let third = identity("third", pid: 43, windowID: 102)
        let requests = [window, other, third].map {
            WindowSpaceRequest(identity: $0, isParked: false, isOnDesktop: true)
        }
        for mode in [WindowSpaceObservation.Mode.verify, .batch] {
            var scalarReads: [Int] = []
            let result = WindowSpaceObservation.capture(
                requests, cancellation: OperationCancellation(),
                layouts: { ["left": layout(1, spaces: [1, 2], fullscreen: [])] },
                membership: { number in
                    scalarReads.append(number)
                    return [2]
                },
                mode: mode,
                windowsInSpace: { space in
                    mode == .batch && space == 2 ? nil : (space == 1 ? [100, 101, 102] : [])
                }
            )
            XCTAssertEqual(scalarReads, [100, 101, 102])
            XCTAssertEqual(result?.memberships, [window: [2], other: [2], third: [2]])
        }
    }

    func testBatchReadsOnlyRequestedDisplayAndUsesScalarForNonDesktopWindows() {
        let additional = identity("additional", pid: 43, windowID: 102)
        let requests = [
            WindowSpaceRequest(identity: window, isParked: false, isOnDesktop: true, displayUUID: "left"),
            WindowSpaceRequest(identity: other, isParked: false, isOnDesktop: true, displayUUID: "left"),
            WindowSpaceRequest(identity: additional, isParked: false, isOnDesktop: false, displayUUID: "left")
        ]
        var batches: [Int] = []
        var scalars: [Int] = []
        let snapshot = WindowSpaceObservation.capture(
            requests, cancellation: OperationCancellation(),
            layouts: { ["left": layout(1, spaces: [1], fullscreen: []),
                        "right": layout(10, spaces: [10, 11], fullscreen: [])] },
            membership: { number in
                scalars.append(number)
                return [1]
            },
            mode: .batch, windowsInSpace: { space in
                batches.append(space)
                return [100, 101, 102]
            }
        )
        XCTAssertEqual(batches, [1])
        XCTAssertEqual(scalars, [102])
        XCTAssertEqual(snapshot?.memberships, [window: [1], other: [1], additional: [1]])
    }

    func testMembershipDiagnosticsRetainSuccessfulScalarFallback() throws {
        let batchFailure = SpaceReadFailure(api: WindowSpaceMembershipReader.batchAPI, reason: .symbolUnavailable)
        let scalarFailure = SpaceReadFailure(api: WindowSpaceMembershipReader.membershipAPI, reason: .invalidType,
                                            field: "response")
        let requests = [window, other].map {
            WindowSpaceRequest(identity: $0, isParked: false, isOnDesktop: true, displayUUID: "left")
        }
        let result = try WindowSpaceObservation.readMemberships(
            requests, layouts: ["left": layout(1, spaces: [1], fullscreen: [])],
            cancellation: OperationCancellation(),
            membership: { $0 == 100 ? .success([1]) : .failure(scalarFailure) },
            windowsInSpace: { _ in .failure(batchFailure) }
        ).get()
        XCTAssertEqual(result.memberships, [window: [1]])
        XCTAssertEqual(result.failures, [batchFailure, scalarFailure])
    }

    func testVerificationDiscardsTheSnapshotIfSpacesChangeDuringComparison() {
        let third = identity("third", pid: 43, windowID: 102)
        let requests = [window, other, third].map {
            WindowSpaceRequest(identity: $0, isParked: false, isOnDesktop: true)
        }
        var current = 1
        let result = WindowSpaceObservation.capture(
            requests, cancellation: OperationCancellation(),
            layouts: { ["left": layout(current, spaces: [1, 2], fullscreen: [])] },
            membership: { _ in [1] }, mode: .verify, windowsInSpace: { _ in
                current = 2
                return [100, 101, 102]
            }
        )
        XCTAssertNil(result)
    }

    func testFullscreenWindowIsExcludedFromOriginalDesktopAndReturnsAfterLeavingFullscreen() {
        var snapshot = WindowSpaceSnapshot(layouts: ["left": layout(1)], memberships: [window: [1]])
        XCTAssertTrue(snapshot.shows(window, on: "left"))
        snapshot.memberships[window] = [3]
        XCTAssertFalse(snapshot.shows(window, on: "left"))
        snapshot.memberships[window] = [1]
        XCTAssertTrue(snapshot.shows(window, on: "left"))
    }

    func testEachMonitorUsesItsOwnCurrentSpaceAndAllSpaceWindowsRemainVisible() {
        let snapshot = WindowSpaceSnapshot(layouts: ["left": layout(1), "right": layout(10, spaces: [10, 11])],
            memberships: [window: [2], other: [10]])
        XCTAssertFalse(snapshot.shows(window, on: "left"))
        XCTAssertFalse(snapshot.shows(other, on: "left"))
        XCTAssertTrue(snapshot.shows(other, on: "right"))
        var sticky = snapshot
        sticky.memberships[window] = [1, 2]
        XCTAssertTrue(sticky.shows(window, on: "left"))
    }

    func testMinimizingPreservesLastSpaceButDoesNotFollowUserToAnotherSpace() {
        let original = WindowSpaceSnapshot(layouts: ["left": layout(1)], memberships: [window: [1]])
        let parked = WindowSpaceRequest(identity: window, isParked: true, isOnDesktop: false)
        let moved = original.updating(with: WindowSpaceSnapshot(layouts: ["left": layout(2)], memberships: [window: []]), requests: [parked])
        XCTAssertEqual(moved.memberships[window], [1])
        XCTAssertFalse(moved.shows(window, on: "left"))
        let returned = moved.updating(with: WindowSpaceSnapshot(layouts: ["left": layout(1)]), requests: [parked])
        XCTAssertTrue(returned.shows(window, on: "left"))
    }

    func testSpaceChangeDoesNotShowANewParkedWindowWithoutMembership() {
        let original = WindowSpaceSnapshot(layouts: ["left": layout(1)])
        let parked = WindowSpaceRequest(identity: window, isParked: true, isOnDesktop: false, displayUUID: "left")
        for memberships: [WindowSpaceIdentity: Set<Int>] in [[:], [window: []]] {
            let observation = WindowSpaceSnapshot(layouts: ["left": layout(2)], memberships: memberships)
            let changed = original.updating(with: observation, requests: [parked], afterSpaceChange: true)
            XCTAssertFalse(changed.shows(window, on: "left"))
            let confirmed = changed.updating(with: .init(layouts: ["left": layout(2)], memberships: [window: [2]]),
                                            requests: [parked])
            XCTAssertTrue(confirmed.shows(window, on: "left"))
        }
    }

    func testLateParkedWindowWaitsForMembershipWhenTheLayoutIsKnown() {
        let request = WindowSpaceRequest(identity: window, isParked: true, isOnDesktop: false,
                                         displayUUID: "left")
        XCTAssertTrue(WindowSpaceSnapshot().updating(with: nil, requests: [request]).shows(window, on: "left"))
        let known = WindowSpaceSnapshot(layouts: ["left": layout(2)])
        let waiting = known.updating(with: nil, requests: [request])
        XCTAssertFalse(waiting.shows(window, on: "left"))
        XCTAssertFalse(waiting.updating(with: known, requests: [request]).shows(window, on: "left"))
    }

    func testLateInactiveWindowWaitsForMembershipAfterAPartialSpaceChange() {
        let original = WindowSpaceSnapshot(layouts: ["left": layout(1)])
        let layout = WindowSpaceSnapshot(layouts: ["left": layout(2)])
        let changed = original.updating(with: layout, requests: [], afterSpaceChange: true)
        let late = WindowSpaceRequest(identity: window, isParked: false, isOnDesktop: true, displayUUID: "left")
        let waiting = changed.updating(with: nil, requests: [late])
        XCTAssertFalse(waiting.shows(window, on: "left"))
        XCTAssertFalse(waiting.updating(with: layout, requests: [late]).shows(window, on: "left"))
    }

    func testLiveUtilityDoesNotRememberThePreviousLayoutDuringASpaceChange() {
        let previous = WindowSpaceSnapshot(layouts: ["left": layout(1)])
        let shown = WindowSpaceRequest(identity: window, isParked: false, isOnDesktop: true,
                                       displayUUID: "left", isUtility: true, isOnActiveSpace: true)
        let parked = WindowSpaceRequest(identity: window, isParked: true, isOnDesktop: false,
                                        displayUUID: "left", isUtility: true)
        let waiting = previous.updating(with: nil, requests: [shown], afterSpaceChange: true)
        let confirmed = waiting.updating(with: .init(layouts: ["left": layout(2)], memberships: [window: [2]]),
                                         requests: [parked], afterSpaceChange: true)
        XCTAssertEqual(confirmed.memberships[window], [2])
        XCTAssertTrue(confirmed.shows(window, on: "left"))
    }

    func testFailedReadsKeepKnownMembershipAndRetiredWindowsArePruned() {
        let original = WindowSpaceSnapshot(layouts: ["left": layout(1)], memberships: [window: [2], other: [1]])
        let request = WindowSpaceRequest(identity: window, isParked: false, isOnDesktop: false)
        let failed = original.updating(with: nil, requests: [request])
        XCTAssertFalse(failed.shows(window, on: "left"))
        XCTAssertNil(failed.memberships[other])
        let partial = failed.updating(with: WindowSpaceSnapshot(layouts: ["left": layout(1)]), requests: [request])
        XCTAssertFalse(partial.shows(window, on: "left"))
    }

    func testChangedDisplayLayoutMakesOnlyItsOmittedMembershipUnconfirmed() {
        let right = layout(10, spaces: [10, 11], fullscreen: [])
        let original = WindowSpaceSnapshot(layouts: ["left": layout(1), "right": right],
            memberships: [window: [2], other: [10]])
        let leftRequest = WindowSpaceRequest(identity: window, isParked: false, isOnDesktop: true, displayUUID: "left")
        let rightRequest = WindowSpaceRequest(identity: other, isParked: false, isOnDesktop: true, displayUUID: "right")
        let layouts = ["left": layout(2), "right": right]
        let partial = original.updating(with: WindowSpaceSnapshot(layouts: layouts), requests: [leftRequest, rightRequest],
                                        afterSpaceChange: true)
        XCTAssertFalse(partial.shows(window, on: "left"))
        XCTAssertTrue(partial.shows(other, on: "right"))

        let parked = WindowSpaceRequest(identity: window, isParked: true, isOnDesktop: false, displayUUID: "left")
        let missing = partial.updating(with: WindowSpaceSnapshot(layouts: layouts, memberships: [window: []]),
                                      requests: [parked, rightRequest])
        XCTAssertFalse(missing.shows(window, on: "left"))
        let recovered = missing.updating(with: WindowSpaceSnapshot(layouts: layouts, memberships: [window: [2]]),
                                         requests: [parked, rightRequest])
        XCTAssertTrue(recovered.shows(window, on: "left"))
    }

    func testChangedWindowIdentityDoesNotInheritRetiredMembership() {
        let replacement = identity(window.itemID, pid: window.actionIdentity.pid, windowID: 200)
        let snapshot = WindowSpaceSnapshot(layouts: ["left": layout(1)], memberships: [window: [2]])
        let updated = snapshot.updating(with: nil, requests: [WindowSpaceRequest(identity: replacement, isParked: false, isOnDesktop: true)])
        XCTAssertNil(updated.memberships[window])
        XCTAssertTrue(updated.shows(replacement, on: "left"))
    }

    func testReplacementWithADifferentGroupCannotReuseAConfirmedWindowNumber() {
        let previous = WindowSpaceRequest(identity: window, isParked: false, isOnDesktop: true)
        let replacement = identity("different-group", pid: window.actionIdentity.pid + 1, windowID: window.windowID)
        let next = WindowSpaceRequest(identity: replacement, isParked: true, isOnDesktop: false)
        let original = WindowSpaceSnapshot().updating(
            with: .init(layouts: ["left": layout(1)], memberships: [window: [2]]), requests: [previous])
        XCTAssertFalse(original.shows(replacement, on: "left"))
        let waiting = original.updating(with: nil, requests: [next])
        XCTAssertFalse(waiting.shows(replacement, on: "left"))
        let absent = original.updating(with: nil, requests: [])
        XCTAssertFalse(absent.updating(with: nil, requests: [next]).shows(replacement, on: "left"))
        let confirmed = waiting.updating(with: .init(layouts: ["left": layout(1)], memberships: [replacement: [1]]),
                                         requests: [next])
        XCTAssertTrue(confirmed.shows(replacement, on: "left"))
    }

    func testReusedWindowNumberKeepsFallbackWhenThereWasNoSpaceEvidence() {
        let prior = WindowSpaceRequest(identity: window, isParked: false, isOnDesktop: true)
        let replacement = identity(window.itemID, pid: window.actionIdentity.pid, windowID: window.windowID,
                                   targetID: UUID())
        let next = WindowSpaceRequest(identity: replacement, isParked: false, isOnDesktop: true)
        let snapshot = WindowSpaceSnapshot().updating(with: nil, requests: [prior])
        XCTAssertTrue(snapshot.shows(replacement, on: "left"))
        XCTAssertTrue(snapshot.updating(with: nil, requests: [next]).shows(replacement, on: "left"))
        let layoutKnown = WindowSpaceSnapshot().updating(with: .init(layouts: ["left": layout(1)]), requests: [prior])
        XCTAssertFalse(layoutKnown.updating(with: nil, requests: [next]).shows(replacement, on: "left"))
        let absent = layoutKnown.updating(with: nil, requests: [])
        XCTAssertFalse(absent.updating(with: nil, requests: [next]).shows(replacement, on: "left"))
    }

    func testSharedSpacesUseTheMainLayoutForBothDisplays() {
        let snapshot = WindowSpaceSnapshot(layouts: ["Main": layout(2)], memberships: [window: [1], other: [2]])
        for display in ["left", "right"] {
            XCTAssertFalse(snapshot.shows(window, on: display))
            XCTAssertTrue(snapshot.shows(other, on: display))
        }
    }

    func testEmptyMembershipForAnOrdinaryWindowIsNotTheCurrentSpace() {
        let request = WindowSpaceRequest(identity: window, isParked: false, isOnDesktop: false)
        let updated = WindowSpaceSnapshot(layouts: ["left": layout(1)], memberships: [window: [1]])
            .updating(with: WindowSpaceSnapshot(layouts: ["left": layout(1)], memberships: [window: []]), requests: [request])
        XCTAssertFalse(updated.shows(window, on: "left"))
    }

    func testLayoutParsingPreservesDisplayIdentityAndFullscreenType() throws {
        let layouts = try XCTUnwrap(ManagedSpaceLayoutReader.parse([
            ["Display Identifier": "left", "Current Space": ["ManagedSpaceID": 3],
             "Spaces": [["ManagedSpaceID": 1, "type": 0], ["ManagedSpaceID": 3, "type": 4]]],
            ["Display Identifier": "right", "Current Space": ["id64": 10],
             "Spaces": [["id64": 10, "type": 0], ["id64": 11, "type": 0]]]
        ]))
        XCTAssertEqual(layouts["left"]?.currentSpaceID, 3)
        XCTAssertEqual(layouts["left"]?.fullscreenSpaceIDs, [3])
        XCTAssertEqual(layouts["right"]?.currentSpaceID, 10)
        XCTAssertEqual(layouts["right"]?.fullscreenSpaceIDs, [])
    }

    func testInconsistentLayoutIsUnknownRatherThanAWindowedDesktop() {
        XCTAssertNil(ManagedSpaceLayoutReader.parse([]))
        XCTAssertNil(ManagedSpaceLayoutReader.parse([["Display Identifier": "left",
            "Current Space": ["ManagedSpaceID": 3], "Spaces": [["ManagedSpaceID": 1, "type": 0]]]]))
        XCTAssertNil(ManagedSpaceLayoutReader.parse([["Display Identifier": "left", "Spaces": []]]))
    }

    func testUnknownSpaceTypeAndDuplicateDisplayDoNotProduceUsableLayouts() {
        XCTAssertNil(ManagedSpaceLayoutReader.parse([
            ["Display Identifier": "left", "Current Space": ["ManagedSpaceID": 1],
             "Spaces": [["ManagedSpaceID": 1, "type": 8]]]
        ]))
        let known: [String: Any] = [
            "Display Identifier": "left", "Current Space": ["ManagedSpaceID": 1],
            "Spaces": [["ManagedSpaceID": 1, "type": 0]]
        ]
        XCTAssertNil(ManagedSpaceLayoutReader.parse([known, known]))
    }

    func testLayoutFailureIdentifiesSchemaFieldAndUnexpectedType() {
        let changed: [[String: Any]] = [
            ["Display Identifier": "left", "Current Space": ["ManagedSpaceID": 1],
             "Spaces": [["ManagedSpaceID": 1, "type": 8]]]
        ]
        XCTAssertEqual(ManagedSpaceLayoutReader.parseChecked(changed), .failure(SpaceReadFailure(
            api: "SLSCopyManagedDisplaySpaces", reason: .unknownSpaceType, field: "Space type", value: 8
        )))
        XCTAssertEqual(ManagedSpaceLayoutReader.parseChecked(["Spaces": []]), .failure(SpaceReadFailure(
            api: "SLSCopyManagedDisplaySpaces", reason: .invalidType, field: "displays"
        )))
    }
}
