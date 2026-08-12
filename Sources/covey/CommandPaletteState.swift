struct CommandPaletteState: Equatable {
    var query = ""
    var selection: AppCommand?

    mutating func reset(
        visible: [AppCommand],
        isEnabled: (AppCommand) -> Bool
    ) {
        query = ""
        selection = visible.first(where: isEnabled) ?? visible.first
    }

    mutating func replaceQuery(
        _ value: String,
        visible: [AppCommand],
        isEnabled: (AppCommand) -> Bool
    ) {
        query = value
        selection = visible.first(where: isEnabled) ?? visible.first
    }

    mutating func move(by delta: Int, visible: [AppCommand]) {
        guard !visible.isEmpty else {
            selection = nil
            return
        }
        let current = selection.flatMap(visible.firstIndex(of:)) ?? 0
        selection = visible[(current + delta + visible.count) % visible.count]
    }
}
