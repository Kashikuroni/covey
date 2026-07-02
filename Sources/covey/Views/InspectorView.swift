import SwiftUI

/// Placeholder for the inspector pane; notes/diffs arrive in a later slice.
struct InspectorView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.right").font(.largeTitle).foregroundStyle(.tertiary)
            Text("Inspector").font(.headline).foregroundStyle(.secondary)
            Text("Notes and diffs arrive in a later slice")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
