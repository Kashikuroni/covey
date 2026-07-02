import SwiftUI

/// Inspector pane: session/project note when one is open, placeholder otherwise.
struct InspectorView: View {
    let model: AppModel

    var body: some View {
        if model.noteTarget != nil {
            NotePane(model: model)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.right").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Inspector").font(.headline).foregroundStyle(.secondary)
                Text("t session note · T project note")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
