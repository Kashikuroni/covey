import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        HSplitView {
            SessionListView(model: model)
                .frame(minWidth: 220, maxWidth: 420)
            TerminalPaneView(model: model)
                .frame(minWidth: 480, minHeight: 320)
        }
        .sheet(item: $model.modal) { modal in
            switch modal {
            case .newSession: NewSessionSheet(model: model)
            case .kill(let name): KillSheet(model: model, name: name)
            case .rename(let name): RenameSheet(model: model, name: name)
            }
        }
        .overlay(alignment: .bottom) { toastBar }
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
