import SwiftUI
import CoveyKit

struct TerminalPaneView: View {
    let model: AppModel

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }
    /// 50/50 split, drag to resize (not persisted).
    @State private var fraction: CGFloat = 0.5

    var body: some View {
        VStack(spacing: 0) {
            if let name = model.selected {
                if let comp = model.companion(of: name) {
                    splitBody(main: name, companion: comp.name,
                              vertical: model.splitAxis(for: name) == "v")
                } else {
                    VStack(spacing: 0) {
                        paneHeader("Agent", badge: 2, name: name)
                        pane(name)
                    }
                    .panelCard(tk, surface: tk.termBg)
                }
            } else if let root = model.selectedProjectRoot {
                VStack(spacing: 0) {
                    paneHeader("Agent", badge: 2, name: "")
                    Spacer()
                    VStack(spacing: 6) {
                        Text(model.displayName(forDir: root))
                            .font(.title3).foregroundStyle(.secondary)
                        Text(collapseHome(root))
                            .font(.caption.monospaced()).foregroundStyle(.tertiary)
                        Text("N — new session")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .panelCard(tk, surface: tk.termBg)
            } else {
                VStack(spacing: 0) {
                    paneHeader("Agent", badge: 2, name: "")
                    Spacer()
                    Text("no session selected").foregroundStyle(.secondary)
                    Spacer()
                }
                .panelCard(tk, surface: tk.termBg)
            }
        }
    }

    @ViewBuilder
    private func splitBody(main: String, companion: String, vertical: Bool) -> some View {
        GeometryReader { geo in
            let total = vertical ? geo.size.width : geo.size.height
            // The gutter eats into the first pane's share, so both panes keep
            // their 120pt floor with the gap in place.
            let usable = max(0, total - Tokens.gutter)
            let first = max(120, min(usable - 120, usable * fraction))
            let layout = vertical
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))
            layout {
                VStack(spacing: 0) {
                    paneHeader("Agent", badge: 2, name: main)
                    pane(main)
                }
                .panelCard(tk, surface: tk.termBg)
                .frame(width: vertical ? first : nil,
                       height: vertical ? nil : first)
                splitDivider(vertical: vertical, usable: usable)
                VStack(spacing: 0) {
                    paneHeader("Terminal", badge: 5, name: companion)
                    pane(companion)
                }
                .panelCard(tk, surface: tk.termBg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .coordinateSpace(name: "termsplit")
    }

    /// Tiny per-pane tab: the focused pane's label lights up in accent.
    private func paneHeader(_ label: String, badge: Int, name: String) -> some View {
        let active = model.focus == .terminal && model.focusedPane == name
        return HStack {
            zoneTitle(label, badge: badge, active: active, tk: tk)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { if !name.isEmpty { model.focusPane(name) } }
    }

    private func pane(_ name: String) -> some View {
        TerminalRepresentable(model: model, name: name)
            .id(name)   // fresh TerminalView per session (spec §5)
            .onTapGesture { model.focusPane(name) }
    }

    private func splitDivider(vertical: Bool, usable: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: vertical ? Tokens.gutter : nil,
                   height: vertical ? nil : Tokens.gutter)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else { NSCursor.pop() }
            }
            .gesture(
                // `fraction` is applied against `usable` (total minus the
                // gutter) by `first` above, so the drag must divide by the
                // same width — dividing by `total` would leave the edge
                // trailing the pointer by the gutter's share of the pane.
                DragGesture(coordinateSpace: .named("termsplit"))
                    .onChanged { value in
                        guard usable > 0 else { return }
                        let pos = vertical ? value.location.x : value.location.y
                        fraction = min(0.85, max(0.15, pos / usable))
                    }
            )
    }

}
