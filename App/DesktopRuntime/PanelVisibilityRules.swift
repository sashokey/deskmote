enum PanelVisibilityState: String, Equatable {
    case unknown
    case desktop
    case fullscreen

    var isVisible: Bool { self == .desktop }
}
