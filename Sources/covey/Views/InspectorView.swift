import SwiftUI

func issueListHeaderFilterLabel(_ state: IssueState) -> String? {
    state == .open ? nil : state.rawValue.uppercased()
}

/// Right drawer: GitHub Issues or the selected agent's trace.
struct InspectorView: View {
    @Bindable var model: AppModel

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }

    var body: some View {
        Group {
            if model.inspectorMode == .trace {
                TracePane(model: model)
                    .panelCard(tk, surface: tk.surface)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        zoneTitle("Issues", badge: 3,
                                  active: model.focus == .inspector, tk: tk)
                        Spacer()
                        if let filter = issueListHeaderFilterLabel(model.issueBrowser.stateFilter) {
                            Text(filter)
                                .font(.system(size: IssueFont.meta, design: .monospaced))
                                .foregroundStyle(tk.accent)
                        }
                        if model.issueBrowser.revalidating {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, Tokens.paneHeaderTop)
                    .padding(.bottom, Tokens.paneHeaderBottom)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.setFocus(.inspector)
                        model.activateIssues()
                    }
                    IssueBrowserPane(model: model)
                }
                .panelCard(tk, surface: tk.surface)
            }
        }
    }
}
