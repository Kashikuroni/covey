import AppKit
import SwiftUI

extension AppModel.Modal: Identifiable {
    public var id: String {
        switch self {
        case .newSession: return "new"
        case .kill(let name): return "kill-\(name)"
        case .rename(let name): return "rename-\(name)"
        }
    }
}

struct NewSessionSheet: View {
    let model: AppModel
    @State private var dir = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var agent = "claude"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New session").font(.headline)
            HStack {
                TextField("Directory", text: $dir)
                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url {
                        dir = url.path
                    }
                }
            }
            TextField("Agent", text: $agent)
            HStack {
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Create") {
                    let (d, a) = (dir, agent)
                    Task {
                        await model.create(dir: d, agent: a)
                        model.modal = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(dir.isEmpty || agent.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct KillSheet: View {
    let model: AppModel
    let name: String

    var body: some View {
        VStack(spacing: 12) {
            Text("Kill session \"\(name)\"?").font(.headline)
            HStack {
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Kill", role: .destructive) {
                    Task {
                        await model.kill(name)
                        model.modal = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

struct RenameSheet: View {
    let model: AppModel
    let name: String
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \"\(name)\"").font(.headline)
            TextField("New name", text: $newName)
            HStack {
                Spacer()
                Button("Cancel") { model.modal = nil }
                Button("Rename") {
                    let target = newName
                    Task {
                        await model.rename(name, to: target)
                        model.modal = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { newName = name }
    }
}
