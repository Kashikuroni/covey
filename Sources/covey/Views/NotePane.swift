import SwiftUI

/// Markdown note with checkbox tasks (port of amux-tui ui/note.rs).
struct NotePane: View {
    @Bindable var model: AppModel
    @State private var editBuffer = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.noteState.editing { editor } else { rendered }
        }
        .onChange(of: model.noteState.editing) { _, editing in
            if editing { editBuffer = model.noteText(); editorFocused = true }
        }
    }

    private var header: some View {
        let counts = taskCounts(model.noteText())
        return HStack(spacing: 8) {
            Text(model.noteTitle()).fontWeight(.semibold).lineLimit(1)
            if counts.total > 0 {
                Text("\(counts.done)/\(counts.total)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.noteState.clearArmed {
                Text("y to clear").font(.caption).foregroundStyle(.red)
            }
            Button(model.noteState.editing ? "Done" : "Edit") {
                if model.noteState.editing { commitEdit() } else { startEdit() }
            }
            .buttonStyle(.borderless).font(.caption)
        }
        .padding(8)
    }

    private var rendered: some View {
        let lines = parseNote(model.noteText())
        var ordinal = -1
        let rows: [(line: NoteLine, ordinal: Int?)] = lines.map { line in
            if case .task = line { ordinal += 1; return (line, ordinal) }
            return (line, nil)
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    renderLine(row.line, ordinal: row.ordinal)
                }
                if model.noteText().isEmpty {
                    Text("e to start writing").font(.caption).foregroundStyle(.tertiary)
                        .padding(.top, 8)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func renderLine(_ line: NoteLine, ordinal: Int?) -> some View {
        switch line {
        case .task(let done, let text):
            let selected = ordinal.map(isSelected) ?? false
            HStack(spacing: 6) {
                Text(ordinal == model.noteState.cursor && model.inputMode == .note ? "›" : " ")
                    .foregroundStyle(.orange).fontWeight(.bold)
                Text(done ? "☑" : "☐")
                Text(text)
                    .strikethrough(done)
                    .foregroundStyle(done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
            .font(.callout)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                if let ordinal { model.setNoteText(toggleTask(model.noteText(), ordinal: ordinal)) }
            }
        case .heading(_, let text):
            Text(text).font(.callout).fontWeight(.bold).padding(.top, 4)
        case .bullet(let text):
            HStack(spacing: 6) { Text("  •"); Text(text) }.font(.callout)
        case .text(let text):
            Text(text).font(.callout)
        case .blank:
            Text(" ").font(.caption2)
        }
    }

    private func isSelected(_ ordinal: Int) -> Bool {
        guard let anchor = model.noteState.visualAnchor else { return false }
        return (min(anchor, model.noteState.cursor)...max(anchor, model.noteState.cursor))
            .contains(ordinal)
    }

    private var editor: some View {
        TextEditor(text: $editBuffer)
            .font(.callout.monospaced())
            .focused($editorFocused)
            .onExitCommand { commitEdit() }
            .padding(4)
    }

    private func startEdit() {
        editBuffer = model.noteText()
        model.setNoteEditing(true)
        editorFocused = true
    }

    private func commitEdit() {
        model.setNoteText(editBuffer)
        model.setNoteEditing(false)
    }
}
