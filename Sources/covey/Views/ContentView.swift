import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let leftWidth = max(220, min(geo.size.width - 480,
                                         geo.size.width * CGFloat(model.splitPct) / 100))
            HStack(spacing: 0) {
                SessionListView(model: model)
                    .frame(width: leftWidth)
                divider(total: geo.size.width)
                TerminalPaneView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(model.themeRaw == "light" ? .light : .dark)
        .sheet(item: $model.modal) { modal in
            switch modal {
            case .newSession: NewSessionSheet(model: model)
            case .kill(let name): KillSheet(model: model, name: name)
            case .rename(let name): RenameSheet(model: model, name: name)
            }
        }
        .overlay(alignment: .bottom) { toastBar }
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color.gray.opacity(0.25))
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        guard total > 0 else { return }
                        model.setSplitPct(Int(value.location.x / total * 100))
                    }
            )
    }

    @ViewBuilder
    private var toastBar: some View {
        if let toast = model.toast {
            HStack(spacing: 12) {
                Text(toast).lineLimit(2)
                if !model.connected {
                    Button("Reconnect") { Task { await model.reconnect() } }
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 12)
        }
    }
}
