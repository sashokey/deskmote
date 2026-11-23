import CoreGraphics
import Foundation

struct TaskbarWindowPresentation: Equatable {
    let item: StripItem
    let title: String
    let isActive: Bool

    var id: String { item.id }
}

struct TaskbarGroupPresentation: Equatable {
    let id: String
    let name: String
    let windows: [TaskbarWindowPresentation]

    var isActive: Bool { windows.contains(where: \.isActive) }
}

enum TaskbarPresentation {
    static func visibleItems(_ items: [StripItem], filter: StripDisplayFilter, spaces: WindowSpaceSnapshot,
                             utilityOnPanelDisplay: (WindowID) -> Bool? = { _ in nil },
                             utilityOnActiveSpace: (WindowID) -> Bool? = { _ in nil }) -> [String: StripItem] {
        let needsPrimaryEvidence = filter.needsPrimaryDisplayEvidence(layoutCount: spaces.layouts.count)
        return Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).filter { _, item in
            let parked = item.status == WindowStatus.minimized.rawValue || item.status == WindowStatus.hidden.rawValue
            let parkedDisplay = parked ? spaces.uniqueDisplay(for: item.spaceIdentity, among: filter.connectedUUIDs) : nil
            let physicalMatch: Bool?
            if case .utility = item.source, parkedDisplay == nil {
                physicalMatch = utilityOnPanelDisplay(item.actionIdentity.windowID)
                guard physicalMatch != false else { return false }
                if needsPrimaryEvidence || (item.utilityDisplayID != nil && item.displayUUID == nil && filter.scope != nil) {
                    guard physicalMatch == true else { return false }
                }
                if physicalMatch == true,
                   let visible = utilityOnActiveSpace(item.actionIdentity.windowID) { return visible }
            } else {
                physicalMatch = nil
            }
            let display = parkedDisplay ?? item.displayUUID
            guard physicalMatch == true || filter.shows(displayUUID: display) else { return false }
            if needsPrimaryEvidence, !spaces.layouts.isEmpty {
                guard let main = spaces.layouts["Main"], let identity = item.spaceIdentity,
                      let memberships = spaces.memberships[identity] else { return false }
                return memberships.contains(main.currentSpaceID)
            }
            if case .utility = item.source, let visible = utilityOnActiveSpace(item.actionIdentity.windowID) {
                return visible
            }
            return spaces.shows(item.spaceIdentity, on: filter.scope ?? filter.resolvedWindowDisplayUUID(display))
        }
    }

    static func groups(items: [StripItem], order: [String], filter: StripDisplayFilter,
                       optimisticStates: [String: OptimisticWindowState],
                       spaces: WindowSpaceSnapshot = WindowSpaceSnapshot(),
                       utilityOnPanelDisplay: (WindowID) -> Bool? = { _ in nil },
                       utilityOnActiveSpace: (WindowID) -> Bool? = { _ in nil },
                       appName: (StripItem) -> String) -> [TaskbarGroupPresentation] {
        let lookup = visibleItems(items, filter: filter, spaces: spaces, utilityOnPanelDisplay: utilityOnPanelDisplay,
                                  utilityOnActiveSpace: utilityOnActiveSpace)
        var groupOrder: [String] = []
        var members: [String: [TaskbarWindowPresentation]] = [:]
        var names: [String: String] = [:]
        for id in order {
            guard let item = lookup[id] else { continue }
            let key = item.applicationKey
            let name = WindowDisplayTitle.bounded(appName(item))
            if members[key] == nil { groupOrder.append(key) }
            names[key] = name
            let status = optimisticStates[item.actionWindowID]?.status.rawValue ?? item.status
            members[key, default: []].append(TaskbarWindowPresentation(
                item: item,
                title: WindowDisplayTitle.resolve(rawTitle: item.title, fallbackName: name),
                isActive: status == WindowStatus.active.rawValue
            ))
        }
        return groupOrder.map {
            TaskbarGroupPresentation(id: $0, name: names[$0] ?? $0, windows: members[$0] ?? [])
        }
    }

    static func actionWindowIDs(_ windows: [TaskbarWindowPresentation]) -> [String] {
        var seen = Set<String>()
        return windows.map(\.item.actionWindowID).filter { seen.insert($0).inserted }
    }
}

enum TaskbarContextAction: Equatable {
    case closeWindow(String)
    case closeWindows([String])
    case quitApplication
}

enum TaskbarContextMenuModel {
    static func actions(button: TaskbarButtonLayout, group: TaskbarGroupPresentation) -> [TaskbarContextAction] {
        let windows = group.windows.filter { button.windowIDs.contains($0.id) }
        let ids = TaskbarPresentation.actionWindowIDs(windows)
        let quit: [TaskbarContextAction] = group.windows.contains { $0.item.allowsApplicationQuit } ? [.quitApplication] : []
        guard let first = ids.first else { return quit }
        return [button.isCombined ? .closeWindows(ids) : .closeWindow(first)] + quit
    }
}
