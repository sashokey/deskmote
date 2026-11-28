import AppKit
import SwiftUI

struct PermissionOnboardingWindowContent: View {
    @ObservedObject var coordinator: PermissionRecoveryCoordinator

    var body: some View {
        ScrollView(.vertical) {
            PermissionOnboardingView(coordinator: coordinator)
        }
        .frame(width: PermissionOnboardingView.contentWidth)
    }
}

struct PermissionOnboardingView: View {
    @ObservedObject var coordinator: PermissionRecoveryCoordinator

    static let contentWidth: CGFloat = 520

    private var presentation: PermissionPresentation {
        coordinator.presentation ?? .waiting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if let message {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
            }
            if let troubleshooting {
                troubleshootingBox(troubleshooting)
            }
            HStack(spacing: 8) {
                Spacer()
                actions
            }
        }
        .padding(28)
        .frame(width: Self.contentWidth, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func troubleshootingBox(_ text: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Switch already on but nothing happens?")
                    .font(.callout.weight(.semibold))
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }


    private var symbolName: String {
        switch presentation {
        case .moveToApplications: return "folder.badge.plus"
        case .waiting, .stalled: return "lock.shield"
        }
    }

    private var title: String {
        switch presentation {
        case .moveToApplications: return String(localized: "Move DeskMote to Applications")
        case .waiting, .stalled: return String(localized: "Turn On Accessibility Permission")
        }
    }

    private var subtitle: String {
        switch presentation {
        case .moveToApplications: return String(localized: "This copy is running from a temporary or read-only location.")
        case .waiting, .stalled: return String(localized: "DeskMote needs this permission to read and manage your windows.")
        }
    }

    private var message: String? {
        switch presentation {
        case .moveToApplications:
            return String(localized: """
            macOS ties Accessibility permission to one specific copy of an app. This copy is running from a \
            temporary or read-only location, so turning the switch on will not take effect — and the permission \
            record stays behind in System Settings after the disk image is ejected. \
            Drag DeskMote to your Applications folder and open it from there.
            """)
        case .waiting, .stalled:
            return String(format: String(localized: "Turn on DeskMote in %@. This window closes by itself once you do, and the taskbar finishes starting."), settingsPath)
        }
    }

    private var troubleshooting: String? {
        let steps = resetSteps
        switch presentation {
        case .stalled:
            return steps
        default:
            return nil
        }
    }

    private var resetSteps: String {
        if #available(macOS 27, *) {
            return String(localized: """
            If the switch is already on and nothing happens, a permission record left by an older version may no \
            longer match this copy of DeskMote. You can reset it:

            1. Quit DeskMote first — while it is running, the minus button in the list is greyed out and the \
            entry cannot be removed.
            2. In Privacy & Security > Device Control and Data Access, select DeskMote in the list and remove it with the minus \
            button. There may be more than one entry; remove them all.
            3. Open DeskMote again from your Applications folder, then add it and turn the switch on when prompted.
            """)
        }
        return String(localized: """
        If the switch is already on and nothing happens, a permission record left by an older version may no \
        longer match this copy of DeskMote. You can reset it:

        1. Quit DeskMote first — while it is running, the minus button in the list is greyed out and the \
        entry cannot be removed.
        2. In Privacy & Security > Accessibility, select DeskMote in the list and remove it with the minus \
        button. There may be more than one entry; remove them all.
        3. Open DeskMote again from your Applications folder, then add it and turn the switch on when prompted.
        """)
    }

    private var settingsPath: String {
        if #available(macOS 27, *) {
            return String(localized: "System Settings > Privacy & Security > Device Control and Data Access")
        }
        return String(localized: "System Settings > Privacy & Security > Accessibility")
    }


    @ViewBuilder
    private var actions: some View {
        switch presentation {
        case .moveToApplications:
            quitButton
            Button("Open Applications Folder") { coordinator.openApplications() }

        case .waiting:
            quitButton
            Button("Open System Settings") { coordinator.openSettings() }

        case .stalled:
            quitButton
            Button("Check Again") { coordinator.recheck() }
            Button("Open System Settings") { coordinator.openSettings() }
        }
    }

    private var quitButton: some View {
        Button("Quit") { coordinator.quit() }
    }
}
