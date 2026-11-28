import CoreGraphics

enum AppsMenuGeometry {
    static let buttonFrame = CGRect(x: 10, y: 2,
                                   width: 29, height: 28)
    static let buttonHitFrame = CGRect(x: 0, y: buttonFrame.minY, width: buttonFrame.maxX, height: buttonFrame.height)
    static let windowLeadingInset = buttonFrame.maxX + 2
    static let popupGap: CGFloat = 12

    static func popupFrame(taskbar: CGRect, screen: CGRect, visibleTop: CGFloat) -> CGRect {
        let inset: CGFloat = 12
        let width = min(642, max(0, screen.width - inset * 2))
        let bottom = taskbar.maxY + popupGap
        let height = min(676, max(0, min(screen.maxY, visibleTop) - 8 - bottom))
        return CGRect(x: screen.minX + inset, y: bottom, width: width, height: height)
    }
}
