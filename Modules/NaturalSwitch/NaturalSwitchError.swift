import Foundation

enum NaturalSwitchError: LocalizedError {
    case unavailableAPI
    case preferences
    case registry(Int32)

    var errorDescription: String? {
        switch self {
        case .unavailableAPI: "The macOS scrolling API is unavailable. Natural Switch cannot run on this system."
        case .preferences: "macOS could not read or apply the global scrolling preference."
        case .registry(let status): "macOS could not monitor connected pointing devices (error \(status))."
        }
    }
}
