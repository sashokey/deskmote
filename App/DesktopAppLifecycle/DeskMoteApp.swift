import AppKit
import SwiftUI

@main
struct DeskMoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        #if DESKMOTE_WIDGET
        let location = AppInstallLocation(bundleURL: Bundle.main.bundleURL, isReadOnlyVolume: PermissionService().isReadOnlyVolume)
        if !location.isTransient { DispatchQueue.global(qos: .utility).async { WidgetRecovery.run() } }
        #endif
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {}
            CommandGroup(replacing: .appInfo) {
                Button {
                    let version = Bundle.main.object(forInfoDictionaryKey: "DeskMoteVersion") as? String ?? ""
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationVersion: version])
                } label: {
                    Text("About DeskMote")
                }
            }
        }
    }
}
