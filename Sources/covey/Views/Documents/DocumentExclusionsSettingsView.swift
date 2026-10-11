import SwiftUI
import CoveyKit

struct DocumentExclusionsSettingsView: View {
    @Binding var configuration: DocumentExclusionConfiguration
    let context: DocumentContext?
    let detected: Set<DocumentPresetID>
    let tk: Tokens
    let onDone: () -> Void
    @State private var scope: DocumentSettingsScope = .global
    @State private var probe = ""
    private var draft: DocumentExclusionDraft { .init(configuration:configuration,projectKey:context?.projectKey) }
    private var value: DocumentScopeExclusions {
        switch scope { case .global: return configuration.global; case .project(let key): return configuration.projects[key] ?? .init() }
    }
    private func update(_ change: (inout DocumentScopeExclusions) -> Void) {
        var edited = value; change(&edited)
        switch scope { case .global: configuration.global = edited; case .project(let key): configuration.projects[key] = edited }
    }
    private func overrideBinding(_ get: @escaping (DocumentScopeExclusions) -> Bool?, _ set: @escaping (inout DocumentScopeExclusions, Bool?) -> Void) -> Binding<Int> {
        Binding(get: { get(value).map { $0 ? 1 : 2 } ?? 0 },set: { selection in update { set(&$0,selection == 0 ? nil : selection == 1) } })
    }
    private func choices(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title,selection:selection) { Text("Automatic / inherit").tag(0); Text("Enabled").tag(1); Text("Disabled").tag(2) }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Document exclusions").font(.headline)
            Text("Controls the file picker and search. Files can still be opened by their exact path or a link. Git ignore rules are independent.").font(.callout).foregroundStyle(tk.t2)
            Picker("Scope",selection:$scope) {
                Text("All projects").tag(DocumentSettingsScope.global)
                if let context { Text("This project").tag(DocumentSettingsScope.project(context.projectKey)) }
            }.pickerStyle(.segmented)
            if case .project(let key) = scope { Text(key).font(.caption).textSelection(.enabled).foregroundStyle(tk.t2) }
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    choices("Built-in exclusions",selection:overrideBinding({ $0.useBuiltins },{ $0.useBuiltins = $1 }))
                    ForEach(DocumentPresetID.allCases,id:\.self) { preset in
                        DisclosureGroup {
                            ForEach(DocumentPresets.rules[preset] ?? [],id:\.self) { rule in
                                choices(rule,selection:overrideBinding({ $0.ruleOverrides[rule] },{ $0.ruleOverrides[rule] = $1 }))
                            }
                        } label: {
                            choices(preset.rawValue.capitalized + (detected.contains(preset) ? " · detected" : ""),selection:overrideBinding({ $0.presetOverrides[preset] },{ $0.presetOverrides[preset] = $1 }))
                        }
                    }
                    DisclosureGroup("Optional build and report folders") {
                        ForEach(DocumentPresets.optionalRules,id:\.self) { rule in
                            choices(rule,selection:overrideBinding({ $0.ruleOverrides[rule] },{ $0.ruleOverrides[rule] = $1 }))
                        }
                    }
                    Text("Custom rules").font(.subheadline.weight(.semibold))
                    Text("One pattern per line. # comments, ! include again, / project root, trailing / folders. Supports *, **, ?, [a-z] and backslash escaping.").font(.caption).foregroundStyle(tk.t2)
                    TextEditor(text:Binding(get:{ value.customRules },set:{ text in update { $0.customRules = text } }))
                        .font(.system(.body,design:.monospaced)).frame(minHeight:140)
                        .overlay(RoundedRectangle(cornerRadius:4).stroke(tk.bd2))
                        .accessibilityLabel("Document exclusion rules")
                    ForEach(Array(draft.validate(detected:detected).enumerated()),id:\.offset) { _, diagnostic in
                        Text("Line \(diagnostic.line): \(diagnostic.message)").font(.caption).foregroundStyle(tk.err)
                    }
                    TextField("Check a project-relative path",text:$probe)
                    if !probe.isEmpty, let rules = try? DocumentExclusionRules.compile(configuration:configuration,projectKey:context?.projectKey ?? "",detected:detected) {
                        let decision = rules.decision(path:probe,isDirectory:probe.hasSuffix("/"))
                        Text(decision.excluded ? "Excluded by \(decision.pattern ?? "rule")\(decision.excludedAncestor.map { " (parent \($0))" } ?? "") · \(sourceLabel(decision.source))" : "Included in the file picker")
                            .font(.caption).foregroundStyle(tk.t2)
                    }
                    HStack {
                        Button("Reset presets") { var edit = draft; edit.resetPresets(scope:scope); configuration = edit.configuration }
                        if case .project = scope {
                            Button("Inherit all project settings") { var edit = draft; edit.inheritProjectSettings(); configuration = edit.configuration }
                        }
                    }
                }.padding(.trailing,4)
            }
            HStack { Text("Changes apply when you save Settings.").font(.caption).foregroundStyle(tk.t2); Spacer(); Button("Done",action:onDone) }
        }
        .frame(width:560,height:620)
    }
    private func sourceLabel(_ source: DocumentRuleSource?) -> String {
        switch source {
        case .builtin(let preset): return "\(preset.capitalized) preset"
        case .global(let line): return "All projects, line \(line)"
        case .project(let line): return "This project, line \(line)"
        case nil: return ""
        }
    }
}
