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
                    paneHeader("Agent", name: name)
                    pane(name)
                }
            } else if let root = model.selectedProjectRoot {
                paneHeader("Agent", name: "")
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
            } else {
                paneHeader("Agent", name: "")
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
                    paneHeader("Agent", name: main)
                    pane(main)
                }
                .frame(width: vertical ? first : nil,
                       height: vertical ? nil : first)
                splitDivider(vertical: vertical, total: total)
                VStack(spacing: 0) {
                    paneHeader("Terminal", name: companion)
                    pane(companion)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .coordinateSpace(name: "termsplit")
    }

    /// Tiny per-pane tab: the focused pane's label lights up in accent.
    private func paneHeader(_ label: String, name: String) -> some View {
        let active = model.focus == .terminal && model.focusedPane == name
        return HStack {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(active ? tk.accent : tk.t4)
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
