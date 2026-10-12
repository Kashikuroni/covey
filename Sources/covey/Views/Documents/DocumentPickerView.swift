import SwiftUI

struct DocumentPickerView: View {
    let model: AppModel
    @FocusState private var searchFocused: Bool
    private var tk: Tokens { Tokens(Theme(raw:model.themeRaw)) }
    var body: some View {
        if let picker = model.documentPicker {
            @Bindable var picker = picker
            let entries = picker.snapshot?.entries ?? []
            let recents = model.documentRecentPaths(root:picker.context?.root ?? "")
            let matches = picker.state.matches(entries:entries,recents:recents)
            VStack(alignment:.leading,spacing:12) {
                Text("Open Project Document").font(.headline)
                if let context = picker.context { Text("\(context.sourceSession) · \(context.root)").font(.caption).foregroundStyle(tk.t2).textSelection(.enabled) }
                HStack {
                    TextField("Find by name or path",text:$picker.state.query).focused($searchFocused)
                        .onSubmit { open(picker) }
                        .onKeyPress(.downArrow) { move(picker,1,entries:matches); return .handled }
                        .onKeyPress(.upArrow) { move(picker,-1,entries:matches); return .handled }
                    Toggle("Markdown only",isOn:$picker.state.markdownOnly).toggleStyle(.checkbox)
                }
                if picker.loading { ProgressView("Scanning project…").controlSize(.small) }
                if let error = picker.error { Text(error).font(.callout).foregroundStyle(tk.err); Button("Retry") { Task { await model.rescanDocumentPicker() } } }
                List(selection:$picker.state.selection) {
                    ForEach(matches) { entry in
                        HStack {
                            Image(systemName:entry.isMarkdown ? "doc.richtext" : "doc.text")
                            Text(entry.path).lineLimit(1)
                            Spacer()
                            if recents.contains(entry.path) { Text("Recent").font(.caption).foregroundStyle(tk.t2) }
                        }.tag(entry.path).contentShape(Rectangle())
                            .onTapGesture(count:2) { Task { await model.openDocument(path:entry.path,viewID:picker.viewID) } }
                    }
                }.overlay { if !picker.loading, matches.isEmpty { Text("No matching files").foregroundStyle(tk.t2) } }
                if let warnings = picker.snapshot?.unreadableDirectories, !warnings.isEmpty { Text("Couldn’t scan: " + warnings.joined(separator:", ")).font(.caption).foregroundStyle(tk.warn) }
                TextField("Exact project path (also opens excluded files)",text:$picker.exactPath)
                    .onSubmit { open(picker) }
                HStack {
                    Text("Read only").font(.caption).foregroundStyle(tk.t2)
                    Spacer()
                    Button("Cancel") { model.modal = nil }
                    Button("Open") { open(picker) }.disabled(picker.context == nil || (picker.exactPath.isEmpty && picker.state.selection == nil))
                }
            }.padding(20).frame(width:640,height:500)
                .onAppear { searchFocused = true }
                .onChange(of:picker.state.query) { _,_ in picker.state.reconcileSelection(entries:entries,recents:recents) }
                .onChange(of:picker.state.markdownOnly) { _,_ in picker.state.reconcileSelection(entries:entries,recents:recents) }
                .onKeyPress(.escape) { model.modal = nil; return .handled }
                .onKeyPress(.return) { open(picker); return .handled }
        }
    }
    private func open(_ picker: DocumentPickerModel) {
        guard let path = picker.exactPath.isEmpty ? picker.state.selection : picker.exactPath else { return }
        Task { await model.openDocument(path:path,viewID:picker.viewID) }
    }
    private func move(_ picker: DocumentPickerModel, _ delta: Int, entries: [DocumentEntry]) {
        guard !entries.isEmpty else { picker.state.selection = nil; return }
        let current = entries.firstIndex(where: { $0.path == picker.state.selection }) ?? 0
        picker.state.selection = entries[min(entries.count-1,max(0,current+delta))].path
    }
}
