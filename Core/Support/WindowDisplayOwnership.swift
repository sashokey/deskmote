import CoreGraphics

enum WindowDisplayAttribution {
    struct Display: Equatable {
        let uuid: String
        let cgFrame: CGRect
        let usableWindowServerFrame: CGRect

        init(uuid: String, cgFrame: CGRect, usableWindowServerFrame: CGRect? = nil) {
            self.uuid = uuid
            self.cgFrame = cgFrame
            self.usableWindowServerFrame = usableWindowServerFrame ?? cgFrame
        }
    }

    struct Table: Equatable {
        let displays: [Display]
        let primaryUUID: String?

        static let empty = Table(displays: [], primaryUUID: nil)

        var orderedUUIDs: [String] { displays.map(\.uuid) }
        var connectedUUIDs: Set<String> { Set(orderedUUIDs) }
    }

    static func displayUUID(for quartzFrame: CGRect?, table: Table) -> String? {
        guard let frame = quartzFrame,
              let index = owningDisplayIndex(
                  for: frame,
                  screenCGFrames: table.displays.lazy.map(\.cgFrame)
              ) else { return nil }
        return table.displays[index].uuid
    }

    static func owningDisplayIndex(for frame: CGRect, screenCGFrames: some Sequence<CGRect>) -> Int? {
        guard isValid(frame) else { return nil }

        let halfWindowArea = frame.width * frame.height * 0.5
        var best: (index: Int, area: CGFloat)?
        for (index, screenFrame) in screenCGFrames.enumerated() {
            guard isValid(screenFrame) else { continue }
            let overlap = frame.intersection(screenFrame)
            guard !overlap.isNull, !overlap.isEmpty else { continue }

            let overlapArea = overlap.width * overlap.height
            if overlapArea >= halfWindowArea { return index }
            if best.map({ overlapArea > $0.area }) ?? true {
                best = (index, overlapArea)
            }
        }
        return best?.index
    }

    private static func isValid(_ frame: CGRect) -> Bool {
        frame.minX.isFinite
            && frame.minY.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }
}
