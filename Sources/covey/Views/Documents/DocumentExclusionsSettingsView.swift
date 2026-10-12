import SwiftUI
import CoveyKit

struct DocumentExclusionsSettingsView: View {
    @Bindable var editor: DocumentExclusionEditor
    let tk: Tokens
    @State private var probe = ""
    private func override(_ get: @escaping (DocumentScopeExclusions) -> Bool?, _ set: @escaping (inout DocumentScopeExclusions,Bool?) -> Void) -> Binding<Int> {
        .init(get:{ get(editor.savedScope).map { $0 ? 1 : 2 } ?? 0 },set:{ selection in editor.update { set(&$0,selection == 0 ? nil : selection == 1) } })
    }
    private func choices(_ title: String, selection: Binding<Int>) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(title).font(.callout)
            Picker(title,selection:selection) { Text("Auto / inherit").tag(0); Text("Exclude").tag(1); Text("Keep visible").tag(2) }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Picker exclusions only. Exact paths, links and open-file refresh remain available.").font(.caption).foregroundStyle(tk.t2)
            Picker("Scope",selection:$editor.scope) {
                Text("All projects").tag(DocumentSettingsScope.global)
                if let context = editor.context { Text("This project").tag(DocumentSettingsScope.project(context.projectKey)) }
            }.pickerStyle(.segmented)
            if case .project(let key) = editor.scope { Text(key).font(.caption).foregroundStyle(tk.t2).textSelection(.enabled) }
            choices("Built-in exclusions",selection:override({ $0.useBuiltins },{ $0.useBuiltins = $1 }))
            ForEach(DocumentPresetID.allCases,id:\.self) { preset in
                DisclosureGroup {
                    choices("Preset policy",selection:override({ $0.presetOverrides[preset] },{ $0.presetOverrides[preset] = $1 }))
                    ForEach((DocumentPresets.rules[preset] ?? []).filter { preset != .swift || $0 != "build/" },id:\.self) { pattern in rule(pattern) }
                    if preset == .swift { Text("Shared build/ policy is listed under Build and report folders.").font(.caption).foregroundStyle(tk.t2) }
                    if (DocumentPresets.rules[preset] ?? []).isEmpty { Text("Uses Node dependency and cache exclusions.").font(.caption).foregroundStyle(tk.t2) }
                } label: {
                    VStack(alignment:.leading,spacing:3) {
                        Text(DocumentPresets.title(preset)).font(.callout.weight(.medium))
                        Text((DocumentPresets.rules[preset] ?? []).joined(separator:" · ")).font(.caption.monospaced()).foregroundStyle(tk.t2).fixedSize(horizontal:false,vertical:true)
                        Text(presetStatus(preset)).font(.caption).foregroundStyle(tk.t2)
                    }
                }
            }
            DisclosureGroup("Build and report folders") {
                Text("Optional by default; build/ is automatic for Swift / Xcode.").font(.caption).foregroundStyle(tk.t2)
                ForEach(DocumentPresets.optionalRules,id:\.self) { pattern in rule(pattern) }
            }
            Text("Custom rules").font(.callout.weight(.medium))
            Text("One glob per line: *, **, ?, [a-z], backslash escapes, # comments, ! include again. / anchors the root; a trailing / matches folders.").font(.caption).foregroundStyle(tk.t2)
            TextEditor(text:$editor.customRules).font(.system(.body,design:.monospaced)).frame(height:130)
                .overlay(RoundedRectangle(cornerRadius:4).stroke(tk.bd2)).accessibilityLabel("Document exclusion rules")
            ForEach(Array(editor.diagnostics.enumerated()),id:\.offset) { _,diagnostic in
                Text("Line \(diagnostic.line): \(diagnostic.message)").font(.caption).foregroundStyle(tk.err)
            }
            HStack {
                Button("Revert") { editor.revertRules() }.disabled(!editor.isDirty)
                Button("Apply rules") { editor.applyRules() }.disabled(!editor.isDirty || !editor.diagnostics.isEmpty)
            }
            Text(editor.isDirty ? "Unsaved rules preview below; close discards these edits." : "Rules are saved. Switches apply immediately.").font(.caption).foregroundStyle(tk.t2)
            TextField("Check a project-relative path",text:$probe).ayuField(tk)
            if !probe.isEmpty, let compiled = editor.compiled {
                let decision = compiled.decision(path:probe,isDirectory:probe.hasSuffix("/"))
                Text(decision.excluded ? "Excluded by \(decision.pattern ?? "rule") · \(source(decision.source))" : "Included in the picker").font(.caption).foregroundStyle(tk.t2)
            }
            DisclosureGroup("Excluded paths in this project") { preview }
            VStack(alignment:.leading,spacing:8) {
                Button("Reset presets") { editor.resetPresets() }
                if case .project = editor.scope { Button("Inherit all project settings") { editor.inheritProject() } }
            }
        }
        .task(id:editor.configuration) { await editor.refreshPreview() }
        .onDisappear { editor.stop() }
    }
    @ViewBuilder private var preview: some View {
        if let context = editor.context {
            Button("Refresh paths") { Task { await editor.refreshPreview() } }.disabled(editor.loading || !editor.diagnostics.isEmpty)
            Text("Effective rules for \(context.root), including project overrides.").font(.caption).foregroundStyle(tk.t2).textSelection(.enabled)
            if !editor.diagnostics.isEmpty { Text("Fix invalid rules to preview exclusions.").font(.caption).foregroundStyle(tk.err) }
            else if editor.loading { ProgressView("Checking project…").controlSize(.small) }
            else if let error = editor.error { Text(error).font(.caption).foregroundStyle(tk.err); Button("Retry") { Task { await editor.refreshPreview() } } }
            else if let snapshot = editor.preview {
                if snapshot.excludedPaths.isEmpty { Text("No paths are currently excluded.").font(.caption) }
                ForEach(snapshot.excludedPaths) { entry in
                    VStack(alignment:.leading,spacing:3) {
                        Text(entry.path + (entry.isDirectory ? "/ — entire folder" : "")).font(.caption.monospaced()).textSelection(.enabled)
                        Text("\(entry.decision.pattern ?? "rule") · \(source(entry.decision.source))").font(.caption).foregroundStyle(tk.t2)
                    }.padding(.vertical,3)
                }
                Text("Showing \(snapshot.excludedPaths.count) of \(snapshot.excludedPathCount) excluded paths. Contents of excluded folders are not scanned or counted.").font(.caption).foregroundStyle(tk.t2)
                if !snapshot.unreadableDirectories.isEmpty { Text("Couldn’t scan: " + snapshot.unreadableDirectories.joined(separator:", ")).font(.caption).foregroundStyle(tk.warn) }
            }
        } else { Text("Select a session to preview excluded paths. Global rules are still editable.").font(.caption).foregroundStyle(tk.t2) }
    }
    private func rule(_ pattern: String) -> some View {
        VStack(alignment:.leading,spacing:3) {
            choices(pattern,selection:override({ $0.ruleOverrides[pattern] },{ $0.ruleOverrides[pattern] = $1 }))
            Text(DocumentPresets.description(pattern)).font(.caption).foregroundStyle(tk.t2)
            Text(editor.compiled?.enabledBuiltinPatterns.contains(pattern) == true ? "Active exclusion; custom rules may override it." : "Not excluded by built-in rules.").font(.caption).foregroundStyle(tk.t2)
        }.padding(.vertical,4)
    }
    private func presetStatus(_ preset: DocumentPresetID) -> String {
        let active = editor.compiled?.enabledPresets.contains(preset) == true
        let project = editor.context.flatMap { editor.settings.configuration.projects[$0.projectKey] }
        if project?.presetOverrides[preset] != nil { return active ? "Enabled for this project" : "Inactive for this project" }
        if editor.settings.configuration.global.presetOverrides[preset] != nil { return active ? "Enabled globally" : "Inactive globally" }
        return active ? "Automatic: active\(editor.detected.contains(preset) ? " · detected" : "")" : "Automatic: inactive"
    }
    private func source(_ value: DocumentRuleSource?) -> String {
        switch value {
        case .builtin(let preset): return preset == "optional" ? "Optional exclusions" : DocumentPresetID(rawValue:preset).map(DocumentPresets.title) ?? preset
        case .global(let line): return "All projects, line \(line)"
        case .project(let line): return "This project, line \(line)"
        case nil: return ""
        }
    }
}
