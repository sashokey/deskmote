import AppKit

typealias TaskbarLeadingSlotFactory = @MainActor (TaskbarLeadingSlotHost) -> TaskbarLeadingSlot

@MainActor
struct TaskbarLeadingSlot {
    let view: NSView
    let leadingInset: CGFloat
    let isPresented: @MainActor () -> Bool
    let update: @MainActor (CGRect, NSWindow?) -> Void
    let dismiss: @MainActor (Bool) -> Void
}

@MainActor
struct TaskbarLeadingSlotHost {
    let admitPopup: @MainActor () -> Bool
    let windowActions: @MainActor (pid_t) -> [TaskbarSlotWindowAction]
}

@MainActor
struct TaskbarSlotWindowAction {
    let title: String
    let isActive: Bool
    let activate: @MainActor () -> Void
}
