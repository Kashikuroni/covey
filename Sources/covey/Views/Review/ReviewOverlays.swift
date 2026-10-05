import SwiftUI

struct ReviewSendSheet: View {
    @Bindable var model: ReviewModel
    let tk: Tokens

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.32).ignoresSafeArea().onTapGesture { model.cancelSend() }
            VStack(alignment: .leading, spacing: 14) {
                Text("SEND TO AGENT").font(ReviewFont.caption()).foregroundStyle(tk.t3)
                HStack(spacing: 8) {
                    Text("Agent").font(.system(size: 12)).foregroundStyle(tk.t3)
                    Picker("Agent", selection: Binding(get: { model.sendDraft?.target ?? "" },
                                                       set: { model.setTarget($0) })) {
                        if model.targets.isEmpty { Text("No agent sessions in this project").tag("") }
                        ForEach(model.targets) { target in
                            Text("\(target.name) · \(target.agent) · \(target.status.rawValue)").tag(target.name)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 340)
                }
                ForEach(model.sendWarnings, id: \.self) { warning in
                    Text("⚠ \(warning)").font(.system(size: 12)).foregroundStyle(tk.warn)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.sendCandidateIssues) { issue in
                        Toggle(isOn: Binding(get: { model.sendDraft?.issueIDs.contains(issue.id) ?? false },
                                             set: { _ in model.toggleSendIssue(issue.id) })) {
                            Text("#\(issue.id) · \(issue.severity.rawValue) — \(issue.title)")
                                .font(.system(size: 12)).lineLimit(1)
                        }
                        .toggleStyle(.checkbox)
                    }
                    ForEach(model.sendCandidateComments) { comment in
                        Toggle(isOn: Binding(get: { model.sendDraft?.commentIDs.contains(comment.id) ?? false },
                                             set: { _ in model.toggleSendComment(comment.id) })) {
                            Text("\(ReviewPrompt.location(comment.anchor)) — \(comment.text)")
                                .font(.system(size: 12)).lineLimit(1)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                ScrollView {
                    Text(model.sendPreview)
                        .font(ReviewFont.mono(11.5))
                        .foregroundStyle(tk.t2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 220)
                .background(tk.surface)
                .overlay(RoundedRectangle(cornerRadius: Tokens.rSm).stroke(tk.bd2))
                Text("The prompt is pasted into the session and submitted. Nothing is written to the repository.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(tk.t3)
                if let error = model.sendError {
                    Text(error).font(.system(size: 12)).foregroundStyle(tk.err)
                }
                HStack {
                    Spacer()
                    ReviewButton(title: "Cancel", tk: tk) { model.cancelSend() }
                    ReviewButton(title: model.sending ? "Sending…" : "Send to \(model.sendDraft?.target ?? "agent")",
                                 prominent: true, tk: tk) {
                        Task { await model.send() }
                    }
                    .disabled(!model.canSend)
                }
            }
            .padding(24)
            .frame(width: 660)
            .background(tk.surf3)
            .overlay(RoundedRectangle(cornerRadius: Tokens.r).stroke(tk.bd3))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.r))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
            .padding(.top, 60)
        }
    }
}

struct ReviewKeysOverlay: View {
    let tk: Tokens
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.32).ignoresSafeArea().onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 12) {
                Text("Keyboard").font(.system(size: 22, weight: .light)).foregroundStyle(tk.t1)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible())],
                          alignment: .leading, spacing: 4) {
                    ForEach(Array(ReviewKeyRouter.help.enumerated()), id: \.offset) { _, entry in
                        HStack {
                            Text(entry.label).foregroundStyle(tk.t2)
                            Spacer()
                            Text(entry.keys).font(ReviewFont.mono(11)).foregroundStyle(tk.t1)
                        }
                        .font(.system(size: 12.5))
                        .padding(.vertical, 5)
                        .overlay(alignment: .bottom) { Rectangle().fill(tk.bd2).frame(height: 1) }
                    }
                }
            }
            .padding(24)
            .frame(width: 560)
            .background(tk.surf3)
            .overlay(RoundedRectangle(cornerRadius: Tokens.r).stroke(tk.bd3))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.r))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
            .padding(.top, 80)
        }
    }
}

struct ReviewToastStack: View {
    let toasts: [ReviewToast]
    let tk: Tokens

    var body: some View {
        VStack(spacing: 6) {
            ForEach(toasts) { toast in
                Text(toast.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(tk.bg)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(tk.t1)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.rSm))
                    .shadow(color: tk.shadowColor, radius: 8, y: 2)
            }
        }
        .padding(.bottom, 72)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: toasts)
    }
}

struct ReviewBanner: View {
    let text: String
    let tk: Tokens
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text("⚠ GIT").font(ReviewFont.caption(11)).foregroundStyle(tk.t1)
            Text(text).font(.system(size: 12.5)).foregroundStyle(tk.t1).lineLimit(2)
            Spacer()
            ReviewButton(title: "Retry", tk: tk, action: retry)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(tk.warn.opacity(0.18))
        .overlay(alignment: .bottom) { Rectangle().fill(tk.bd2).frame(height: 1) }
    }
}
