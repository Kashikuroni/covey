import SwiftUI
import CoveyKit

/// The selected session's PROJECT note in the same vim editor as the issue
/// body, opening in PREVIEW (obsidian-style read view). Session-level notes
/// are gone — the project note is always right here.
struct NotePane: View {
    @Bindable var model: AppModel

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }
    private var root: String? { model.sessionRootOfSelected() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let root {
                let counts = taskCounts(model.projectNotes[root] ?? "")
                HStack(spacing: 6) {
                    Text(model.displayName(forDir: root))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if counts.total > 0 {
                        Text("\(counts.done)/\(counts.total)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                VimEditor(text: Binding(
                    get: { model.projectNotes[root] ?? "" },
                    set: { model.setProjectNote(dir: root, text: $0) }),
                          modeBadge: Binding(
                    get: { model.inspectorVimBadge ?? "" },
                    set: { model.inspectorVimBadge = $0.isEmpty ? nil : $0 }),
                          tk: tk,
                          startInPreview: true,
                          focusTick: model.noteFocusTick,
                          onSwitchField: { _ in })
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            } else {
                Text("select a session")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
