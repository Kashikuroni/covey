import SwiftUI
import CoveyGit

struct ReviewTopBar: View {
    @Bindable var model: ReviewModel
    let tk: Tokens

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(projectDefaultName(model.projectRoot))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tk.t1)
                Text(model.branchLabel).font(ReviewFont.mono(11)).foregroundStyle(tk.t3)
            }
            .lineLimit(1)
            divider
            Button { model.comparisonPopoverOpen = true } label: {
                HStack(spacing: 8) {
                    Text(model.record.comparison.base.isEmpty ? "Choose comparison" : model.record.comparison.label)
                        .font(ReviewFont.mono(12))
                        .foregroundStyle(tk.t1)
                    Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(tk.t3)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(tk.surf2)
                .overlay(RoundedRectangle(cornerRadius: Tokens.rSm).stroke(tk.bd3))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $model.comparisonPopoverOpen, arrowEdge: .bottom) {
                ComparisonEditor(model: model, tk: tk)
            }
            Spacer(minLength: 12)
            ReviewTargetMenu(model: model, tk: tk)
            ReviewButton(title: model.unsentCount > 0 ? "Send review · \(model.unsentCount)" : "Send review",
                         prominent: model.unsentCount > 0, tk: tk) { model.beginSend() }
                .disabled(model.unsentCount == 0)
            divider
            HStack(spacing: 10) {
                Text("\(model.reviewedCount) / \(model.files.count)")
                    .font(ReviewFont.mono(12, weight: .medium))
                    .foregroundStyle(tk.t1)
                Text("reviewed").font(.system(size: 12)).foregroundStyle(tk.t3)
                ProgressView(value: model.progressFraction)
                    .progressViewStyle(.linear)
                    .frame(width: 96)
                    .tint(tk.t1)
                ReviewButton(title: "Next unreviewed", hint: "U", tk: tk) {
                    Task { await model.nextUnreviewed() }
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(tk.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(tk.bd2).frame(height: 1) }
    }

    private var divider: some View {
        Rectangle().fill(tk.bd2).frame(width: 1, height: 20)
    }
}

struct ReviewTargetMenu: View {
    @Bindable var model: ReviewModel
    let tk: Tokens

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(reviewStatusColor(model.target?.status, tk)).frame(width: 7, height: 7)
            Menu {
                if model.targets.isEmpty { Text("No agent sessions in this project") }
                ForEach(model.targets) { target in
                    Button("\(target.name) · \(target.agent) · \(target.status.rawValue)") {
                        model.setTarget(target.name)
                    }
                }
            } label: {
                Text(label).font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            if let status = model.target?.status {
                Text(status.rawValue).font(.system(size: 12)).foregroundStyle(tk.t3)
            }
        }
        .help("The agent session that receives the review")
    }

    private var label: String {
        if let target = model.target { return target.name }
        if let name = model.record.targetSession { return "\(name) · session ended" }
        return "Choose agent"
    }
}

struct ComparisonEditor: View {
    @Bindable var model: ReviewModel
    let tk: Tokens
    @State private var base = ""
    @State private var compareRef = false
    @State private var headRef = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("COMPARISON").font(ReviewFont.caption()).foregroundStyle(tk.t3)
            if case .needsComparison(let error?) = model.phase {
                Text(error).font(.system(size: 12)).foregroundStyle(tk.err)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Base").font(.system(size: 11)).foregroundStyle(tk.t3)
                    refField($base)
                }
                Text("↔").foregroundStyle(tk.t3).padding(.top, 22)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Compare").font(.system(size: 11)).foregroundStyle(tk.t3)
                    Picker("Compare", selection: $compareRef) {
                        Text("Working tree").tag(false)
                        Text("Branch or commit").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    if compareRef { refField($headRef) }
                }
            }
            HStack {
                Spacer()
                ReviewButton(title: "Cancel", tk: tk) { model.comparisonPopoverOpen = false }
                ReviewButton(title: "Start review", prominent: true, tk: tk) { start() }
                    .disabled(!isValid)
            }
        }
        .padding(16)
        .frame(width: 460)
        // The popover is a window of its own; it follows covey's theme too.
        .preferredColorScheme(tk.isDark ? .dark : .light)
        .onAppear {
            let current = model.record.comparison
            base = current.base.isEmpty ? (model.suggestedBase ?? "") : current.base
            if case .ref(let ref) = current.head {
                compareRef = true
                headRef = ref
            }
        }
    }

    private func refField(_ text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            TextField("branch or commit", text: text)
                .textFieldStyle(.roundedBorder)
                .font(ReviewFont.mono(12))
            Menu {
                ForEach(model.localBranches, id: \.self) { branch in
                    Button(branch) { text.wrappedValue = branch }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var isValid: Bool {
        !trimmed(base).isEmpty && (!compareRef || !trimmed(headRef).isEmpty)
    }

    private func start() {
        let comparison = GitComparison(base: trimmed(base),
                                       head: compareRef ? .ref(trimmed(headRef)) : .workingTree)
        model.comparisonPopoverOpen = false
        Task { await model.open(comparison) }
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
