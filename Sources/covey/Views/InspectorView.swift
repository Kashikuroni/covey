import SwiftUI

/// Right drawer: zone tabs Note/Issue, tabs or vertical split, nvim-style
/// INSERT/NORMAL badge in the bottom-right corner.
struct InspectorView: View {
    @Bindable var model: AppModel

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        VStack(spacing: 0) {
            tabsHeader
            if model.inspectorSplit {
                NotePane(model: model)
                Divider()
                IssuePane(model: model)
            } else if model.inspectorTab == .note {
                NotePane(model: model)
            } else {
                IssuePane(model: model)
            }
        }
    }

    private var tabsHeader: some View {
        HStack(spacing: 12) {
            tab("Note", .note)
            tab("Issue", .issue)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tk.surface)
    }

    private func tab(_ label: String, _ value: AppModel.InspectorTab) -> some View {
        // Lit only when the zone actually owns the focus — matching the
        // Session/Agent/Terminal zone tabs.
        let active = model.focus == .inspector && model.inspectorTab == value
        return Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(active ? tk.accent : tk.t4)
            .contentShape(Rectangle())
            .onTapGesture {
                model.setFocus(.inspector)
                model.selectInspectorTab(value)
            }
    }
}
