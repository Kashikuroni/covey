import SwiftUI

/// Right drawer: zone tabs Note/Issue, tabs or vertical split, nvim-style
/// INSERT/NORMAL badge in the bottom-right corner.
struct InspectorView: View {
    @Bindable var model: AppModel

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        VStack(spacing: 0) {
            if model.inspectorSplit {
                // Split shows both panes — a shared tab row would lie about
                // what a click does. Each pane carries its own zone header.
                paneHeader("Note", badge: 3, tab: .note)
                NotePane(model: model)
                Divider()
                paneHeader("Issue", badge: 4, tab: .issue)
                IssueBrowserPane(model: model)
            } else {
                tabsHeader
                if model.inspectorTab == .note {
                    NotePane(model: model)
                } else {
                    IssueBrowserPane(model: model)
                }
            }
        }
    }

    private var tabsHeader: some View {
        HStack(spacing: 12) {
            tab("Note", badge: 3, .note)
            tab("Issue", badge: 4, .issue)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tk.surface)
    }

    private func tab(_ label: String, badge: Int,
                     _ value: AppModel.InspectorTab) -> some View {
        // Lit only when the zone actually owns the focus — matching the
        // Session/Agent/Terminal zone tabs.
        let active = model.focus == .inspector && model.inspectorTab == value
        return zoneTitle(label, badge: badge, active: active, tk: tk)
            .contentShape(Rectangle())
            .onTapGesture {
                model.setFocus(.inspector)
                model.selectInspectorTab(value)
            }
    }

    /// Per-pane zone header for the split mode: same strip look as the tab
    /// row, highlighted for the pane that owns the inspector focus.
    private func paneHeader(_ label: String, badge: Int,
                            tab: AppModel.InspectorTab) -> some View {
        let active = model.focus == .inspector && model.inspectorTab == tab
        return HStack {
            zoneTitle(label, badge: badge, active: active, tk: tk)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tk.surface)
        .contentShape(Rectangle())
        .onTapGesture {
            model.setFocus(.inspector)
            model.selectInspectorTab(tab)
        }
    }
}
