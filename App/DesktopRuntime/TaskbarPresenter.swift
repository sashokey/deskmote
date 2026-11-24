import AppKit
import Combine

@MainActor
final class TaskbarPresenter {
    private let runtime: AppRuntime
    private let ordering: StripOrderStore
    private let topology: DisplayTopologyStore
    private let spaces: TaskbarSpaceStore
    private let displayUUID: String?
    private weak var view: TaskbarView?
    private var subscriptions = Set<AnyCancellable>()
    private var refreshing = false
    private var liveIDs: [String] = []
    private var renderedSpaceRevision: UInt64 = 0
    private var panelAllowsWindowActions = true
    private let panelInvalidations = PassthroughSubject<Void, Never>()

    init(view: TaskbarView, runtime: AppRuntime, ordering: StripOrderStore,
         topology: DisplayTopologyStore, spaces: TaskbarSpaceStore, displayUUID: String?,
         backgroundMenu: @escaping (NSEvent, NSView) -> Void,
         popupPresented: @escaping (NSPanel) -> Void,
         contextMenuVisibilityChanged: @escaping (Bool) -> Void,
         icons: AppIconResolver = .shared, system: any WindowSystemAccess = NativeWindowSystem()) {
        self.view = view
        self.runtime = runtime
        self.ordering = ordering
        self.topology = topology
        self.spaces = spaces
        self.displayUUID = displayUUID
        view.taskbarContent.canUseWindowActions = { [weak self] in
            guard let self, self.panelAllowsWindowActions else { return false }
            return self.allowsExternalProjection(revision: self.renderedSpaceRevision)
                || (self.renderedOnlyLiveUtility && self.visibleItems().values.contains(where: self.isLiveUtility))
        }
        view.taskbarContent.actions = TaskbarViewActions(
            toggle: { [weak self] in self?.trigger(.toggle($0.windowID), expected: $0) },
            activate: { [weak self] in self?.trigger(.activate($0.windowID), expected: $0) },
            close: { [weak self] in self?.trigger(.close($0.windowID), expected: $0) },
            quit: { [weak self] group in
                guard let self, self.panelAllowsWindowActions,
                      self.allowsExternalProjection(revision: self.renderedSpaceRevision) else { return }
                let visible = self.visibleItems()
                var attempted = Set<pid_t>()
                for window in group.windows {
                    let item = window.item
                    guard item.allowsApplicationQuit,
                          visible[item.id]?.actionIdentity == item.actionIdentity,
                          let app = system.app(item.pid), !app.isTerminated,
                          let expected = item.processGeneration,
                          system.generation(item.pid) == expected,
                          app.origin == item.applicationOrigin else { continue }
                    let pid = item.owningApplication?.pid ?? item.pid
                    if let owner = item.owningApplication {
                        guard let parent = system.app(pid), !parent.isTerminated,
                              system.generation(pid) == owner.generation,
                              parent.origin == owner.origin else { continue }
                    }
                    guard attempted.insert(pid).inserted else { continue }
                    _ = system.terminate(pid, generation: item.owningApplication?.generation ?? expected,
                                         origin: item.owningApplication?.origin ?? item.applicationOrigin)
                }
            },
            reorder: { [weak self] app, target, after in
                guard let self else { return }
                self.ordering.reorderGroup(app, relativeTo: target, after: after, current: self.liveIDs)
            },
            backgroundMenu: backgroundMenu,
            popupPresented: popupPresented,
            contextMenuVisibilityChanged: contextMenuVisibilityChanged
        )
        view.taskbarContent.iconProvider = { item in
            if let bundleID = item.item.bundleIdentifier { return icons.icon(for: bundleID, origin: item.item.resourceOrigin) }
            return NSRunningApplication(processIdentifier: item.item.resourcePID)?.icon
        }
        runtime.$snapshot.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        runtime.$optimisticStatesByWindowID.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        ordering.$liveOrder.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        topology.$table.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        topology.$physicalDisplayCount.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        spaces.activeSpaceChanges.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        spaces.$snapshot.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        spaces.$confirmedSpaceRevision.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        icons.changes.sink { [weak self] in self?.scheduleRefresh(refreshIcons: true) }.store(in: &subscriptions)
        refresh()
    }

    private var refreshScheduled = false
    private var iconsDirty = false
    private var renderedOnlyLiveUtility = false

    private var displayFilter: StripDisplayFilter {
        StripDisplayFilter(scope: displayUUID, connectedUUIDs: topology.table.connectedUUIDs,
                           primaryUUID: topology.table.primaryUUID, physicalDisplayCount: topology.physicalDisplayCount)
    }

    private func visibleItems() -> [String: StripItem] {
        TaskbarPresentation.visibleItems(StripItem.openWindows(from: runtime.snapshot),
                                       filter: displayFilter, spaces: spaces.snapshot,
                                       utilityOnPanelDisplay: utilityOnPanelDisplay,
                                       utilityOnActiveSpace: { runtime.utilityWindowOnActiveSpace($0) })
    }

    private func allowsExternalProjection(revision: UInt64) -> Bool {
        if displayFilter.needsPrimaryDisplayEvidence(layoutCount: spaces.snapshot.layouts.count),
           !spaces.snapshot.layouts.isEmpty, spaces.snapshot.layouts["Main"] == nil { return false }
        return spaces.canUseProjection(on: displayUUID ?? topology.table.primaryUUID, renderedSpaceRevision: revision)
    }

    private func utilityOnPanelDisplay(_ id: WindowID) -> Bool? {
        let screen: NSScreen?
        if let displayUUID {
            screen = view?.window?.screen.flatMap {
                DisplayIdentity.uuidString(for: $0) == displayUUID ? $0 : nil
            }
        } else {
            screen = NSScreen.screens.first
        }
        guard let screen, let panelID = DisplayIdentity.displayID(for: screen),
              let utilityID = runtime.utilityWindowPhysicalDisplayID(id) else { return nil }
        return panelID == utilityID
    }

    private func isLiveUtility(_ item: StripItem) -> Bool {
        guard case .utility = item.source else { return false }
        return runtime.utilityWindowOnActiveSpace(item.actionIdentity.windowID) == true
    }

    private func trigger(_ intent: UserIntent, expected: WindowActionIdentity) {
        let revision = renderedSpaceRevision
        let invalidations = spaces.activeSpaceChanges.merge(with: panelInvalidations).eraseToAnyPublisher()
        runtime.trigger(intent, expected: expected, projectionInvalidations: invalidations) { [weak self] in
            guard let self, self.view != nil, self.panelAllowsWindowActions,
                  let item = self.visibleItems()[expected.groupID], item.actionIdentity == expected else { return false }
            return self.isLiveUtility(item) || self.allowsExternalProjection(revision: revision)
        }
    }

    func setPanelVisible(_ visible: Bool) {
        guard panelAllowsWindowActions != visible else { return }
        panelAllowsWindowActions = visible
        if !visible { panelInvalidations.send() }
    }

    private func scheduleRefresh(refreshIcons: Bool = false) {
        iconsDirty = iconsDirty || refreshIcons
        guard !refreshing, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    private func refresh() {
        guard !refreshing, let view else { return }
        refreshing = true
        let refreshIcons = iconsDirty
        iconsDirty = false
        defer {
            refreshing = false
            if iconsDirty { scheduleRefresh() }
        }
        let items = StripItem.openWindows(from: runtime.snapshot)
        liveIDs = items.map(\.id)
        let keys = Dictionary(items.map { ($0.id, $0.applicationKey) }, uniquingKeysWith: { first, _ in first })
        ordering.sync(current: liveIDs, appKeyOf: keys)
        let order = TaskbarGroupOrdering.contiguous(ordering.reconciled(current: liveIDs, appKeyOf: keys), appKeys: keys)
        let confirmedSpaceRevision = spaces.confirmedSpaceRevision
        let permitsExternal = allowsExternalProjection(revision: confirmedSpaceRevision)
        let liveUtility = permitsExternal ? [] : visibleItems().values.filter(isLiveUtility)
        renderedOnlyLiveUtility = !liveUtility.isEmpty
        let activeItemID = runtime.effectiveActiveWindowID.flatMap { runtime.snapshot.windows[$0]?.groupID }
        let groups = TaskbarPresentation.groups(items: renderedOnlyLiveUtility ? liveUtility : items, order: order, filter: displayFilter,
                                                activeItemID: activeItemID,
                                                spaces: spaces.snapshot,
                                                utilityOnPanelDisplay: utilityOnPanelDisplay,
                                                utilityOnActiveSpace: { runtime.utilityWindowOnActiveSpace($0) }) { item in
            if let bundleID = item.bundleIdentifier { return AppDisplayNameResolver.displayName(for: bundleID, origin: item.resourceOrigin) }
            return NSRunningApplication(processIdentifier: item.resourcePID)?.localizedName ?? item.appID
        }
        view.taskbarContent.update(groups: groups, refreshIcons: refreshIcons)
        renderedSpaceRevision = confirmedSpaceRevision
    }
}
