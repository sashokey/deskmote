import Carbon

@MainActor
enum SystemInputSources {
    static func selectNext() -> OSStatus {
        selectNext(
            readSources: available,
            readCurrent: { TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() },
            identifier: identifier,
            select: { TISSelectInputSource($0) }
        )
    }

    static func selectNext<Source>(
        readSources: (CFDictionary) -> [Source],
        readCurrent: () -> Source?,
        identifier: (Source) -> String?,
        select: (Source) -> OSStatus
    ) -> OSStatus {
        let filter = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsEnabled: true,
            kTISPropertyInputSourceIsSelectCapable: true
        ] as CFDictionary
        let sources = readSources(filter).compactMap { source in
            identifier(source).map { (id: $0, source: source) }
        }
        let currentID = readCurrent().flatMap(identifier)
        guard let nextID = InputSourceCycle.next(after: currentID, in: sources.map(\.id)),
              let next = sources.first(where: { $0.id == nextID }) else { return noErr }
        return select(next.source)
    }

    private static func available(matching filter: CFDictionary) -> [TISInputSource] {
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() else { return [] }
        return list as? [TISInputSource] ?? []
    }

    private static func identifier(_ source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
