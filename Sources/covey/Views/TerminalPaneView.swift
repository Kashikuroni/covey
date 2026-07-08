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
                    paneHeader("Agent", badge: 2, name: name)
                    pane(name)
                }
            } else {
                paneHeader("Agent", badge: 2, name: "")
                Spacer()
                Text("no session selected").foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func splitBody(main: String, companion: String, vertical: Bool) -> some View {
        GeometryReader { geo in
            let total = vertical ? geo.size.width : geo.size.height
            let first = max(120, min(total - 120, total * fraction))
            let layout = vertical
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))
            layout {
                VStack(spacing: 0) {
                    paneHeader("Agent", badge: 2, name: main)
                    pane(main)
                }
                .frame(width: vertical ? first : nil,
                       height: vertical ? nil : first)
                splitDivider(vertical: vertical, total: total)
                VStack(spacing: 0) {
                    paneHeader("Terminal", badge: 5, name: companion)
                    pane(companion)
                }
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
        .background(tk.surface)
        .contentShape(Rectangle())
        .onTapGesture { if !name.isEmpty { model.focusPane(name) } }
    }

    private func pane(_ name: String) -> some View {
        TerminalRepresentable(model: model, name: name)
            .id(name)   // fresh TerminalView per session (spec §5)
            .onTapGesture { model.focusPane(name) }
    }

    private func splitDivider(vertical: Bool, total: CGFloat) -> some View {
        Rectangle()
            .fill(Color.gray.opacity(0.25))
            .frame(width: vertical ? 5 : nil, height: vertical ? nil : 5)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .named("termsplit"))
                    .onChanged { value in
                        guard total > 0 else { return }
                        let pos = vertical ? value.location.x : value.location.y
                        fraction = min(0.85, max(0.15, pos / total))
                    }
            )
    }

}
