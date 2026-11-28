import AppKit
import SwiftUI

@main
struct DeskMoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

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
