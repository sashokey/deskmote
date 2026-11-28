import AppKit
import DeskMoteApps

@MainActor
func makeFullLeadingSlotFactory(module: AppsModule) -> TaskbarLeadingSlotFactory {
    { host in
        let attachment = module.attach(admitPopup: host.admitPopup) { pid in
            host.windowActions(pid).map { window in
                AppsWindowAction(title: window.title, isActive: window.isActive, activate: window.activate)
            }
        }
        return TaskbarLeadingSlot(view: attachment.view, leadingInset: attachment.leadingInset,
                                  isPresented: { attachment.isPresented }, update: attachment.update,
                                  dismiss: attachment.dismiss)
    }
}

@MainActor
func makeProductionLeadingSlotFactory() -> TaskbarLeadingSlotFactory {
    return makeFullLeadingSlotFactory(module: AppsModule(
        appearance: appsTaskbarAppearance, makePanel: TaskbarPopupController.makeStandardPanel,
        makeMenuItem: TaskbarNativeMenuFactory.actionItem,
        isDeskMote: ApplicationIdentity.isDeskMote
    ))
}

@MainActor
var appsTaskbarAppearance: AppsAppearance {
    AppsAppearance(buttonCornerRadius: TaskbarMetrics.buttonCornerRadius,
                   buttonTransition: TaskbarMotion.buttonTransition, reorderTransition: TaskbarMotion.reorderTransition) {
        active, hovered, pressed, box, appearance in
        let selection = TaskbarButtonSelection(active: active, hovered: hovered, pressed: pressed)
        selection.applyColors(to: box, appearance: appearance)
        return selection.opacity
    }
}
