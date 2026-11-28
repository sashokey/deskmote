import CoreGraphics

enum PanelVisibilityState: String, Equatable {
    case unknown
    case desktop
    case fullscreen

    var isVisible: Bool { self == .desktop }
}

enum BorderlessFullscreenGame {
    static let bundleIdentifier = "com.blizzard.worldofwarcraft"

    static func display(for frame: CGRect?, in table: WindowDisplayAttribution.Table) -> String? {
        guard let frame else { return nil }
        return table.displays.first { $0.cgFrame == frame }?.uuid
    }
}
