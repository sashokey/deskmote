import AppKit

@MainActor
enum Alerts {
    static func error(
        _ title: String, _ message: String,
        present: @MainActor (NSAlert) -> NSApplication.ModalResponse = present
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = present(alert)
    }

    private static func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApplication.shared.activate()
        return alert.runModal()
    }
}
