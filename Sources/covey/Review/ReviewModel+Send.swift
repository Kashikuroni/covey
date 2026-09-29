import Foundation
import CoveyKit

extension ReviewModel {
    var targets: [ReviewTarget] { directory?.reviewTargets(projectRoot: projectRoot) ?? [] }

    /// The chosen target if it is still alive.
    var target: ReviewTarget? { targets.first { $0.name == record.targetSession } }

    func setTarget(_ name: String) {
        record.targetSession = name
        sendDraft?.target = name
        persist()
    }

    /// `Open` = not sent yet, or reopened after a failed fix.
    var unsentIssues: [ReviewIssue] {
        record.issues.filter { $0.status == .open }.sorted { $0.id < $1.id }
    }

    var unsentComments: [ReviewComment] {
        record.comments.filter { $0.sentAt == nil }
            .sorted { ($0.anchor.path, $0.anchor.line) < ($1.anchor.path, $1.anchor.line) }
    }

    var unsentCount: Int { unsentIssues.count + unsentComments.count }

    /// Opens the send sheet: everything unsent, or just `issue`.
    func beginSend(issue id: Int? = nil) {
        let issues = id.map { [$0] } ?? unsentIssues.map(\.id)
        let comments = id == nil ? unsentComments.map(\.id) : []
        sendError = nil
        sendDraft = SendDraft(target: record.targetSession, candidateIssueIDs: issues,
                              candidateCommentIDs: comments, issueIDs: Set(issues),
                              commentIDs: Set(comments))
    }

    /// Closes the sheet. A delivery already under way is not interrupted:
    /// the text is on its way to the session either way.
    func cancelSend() {
        sendDraft = nil
        sendError = nil
    }

    func toggleSendIssue(_ id: Int) {
        guard sendDraft != nil else { return }
        if sendDraft!.issueIDs.contains(id) { sendDraft!.issueIDs.remove(id) } else { sendDraft!.issueIDs.insert(id) }
    }

    func toggleSendComment(_ id: UUID) {
        guard sendDraft != nil else { return }
        if sendDraft!.commentIDs.contains(id) { sendDraft!.commentIDs.remove(id) } else { sendDraft!.commentIDs.insert(id) }
    }

    var sendCandidateIssues: [ReviewIssue] {
        (sendDraft?.candidateIssueIDs ?? []).compactMap { id in record.issues.first { $0.id == id } }
    }

    var sendCandidateComments: [ReviewComment] {
        (sendDraft?.candidateCommentIDs ?? []).compactMap { id in record.comments.first { $0.id == id } }
    }

    var promptContext: ReviewPromptContext {
        ReviewPromptContext(branch: branchLabel, comparison: record.comparison.label, worktree: worktree)
    }

    var sendPreview: String {
        guard let draft = sendDraft else { return "" }
        return ReviewPrompt.build(context: promptContext,
                                  issues: sendCandidateIssues.filter { draft.issueIDs.contains($0.id) },
                                  comments: sendCandidateComments.filter { draft.commentIDs.contains($0.id) })
    }

    /// Bytes the paste would write, markers included.
    var sendPayloadSize: Int { ReviewSender.pastePayload(sendPreview).count }

    var sendWarnings: [String] {
        guard let draft = sendDraft else { return [] }
        var warnings: [String] = []
        if let name = draft.target, let target = targets.first(where: { $0.name == name }) {
            switch target.status {
            case .waiting:
                warnings.append("\(target.name) is waiting on a prompt — answer it in the session first.")
            case .running:
                warnings.append("\(target.name) is running — the message will be queued.")
            case .idle:
                break
            }
            let root = URL(fileURLWithPath: worktree).resolvingSymlinksInPath().path
            let dir = URL(fileURLWithPath: target.dir).resolvingSymlinksInPath().path
            if dir != root, !dir.hasPrefix(root + "/") {
                warnings.append("\(target.name) works in \(target.dir); paths in the prompt are relative to \(worktree).")
            }
        }
        let size = sendPayloadSize
        if size > ReviewSender.maxPasteBytes {
            let kb = Int((Double(size) / 1024).rounded(.up))
            warnings.append("The review is too large to paste (\(kb) KB) — send fewer items.")
        }
        return warnings
    }

    /// A target showing a selection/permission prompt (`.waiting`) must not
    /// receive the paste: its Enter would answer the prompt (e.g. approve a
    /// tool call). An oversized paste would be dropped by the daemon.
    var canSend: Bool {
        guard let draft = sendDraft, !sending, let name = draft.target,
              let target = targets.first(where: { $0.name == name }),
              target.status != .waiting else { return false }
        guard !draft.issueIDs.isEmpty || !draft.commentIDs.isEmpty else { return false }
        return sendPayloadSize <= ReviewSender.maxPasteBytes
    }

    /// Delivers the preview; only a fully successful delivery marks items sent.
    ///
    /// Delivery can outlive a comparison switch. The text has then reached
    /// the session, so the sheet closes and the toast shows, but `record` is
    /// another comparison's and no item in it is marked.
    func send() async {
        guard canSend, let draft = sendDraft, let name = draft.target, let directory else { return }
        let text = sendPreview
        let generation = loadGeneration
        sending = true
        defer { sending = false }
        do {
            try await ReviewSender.deliver(text, to: name, via: directory, enterDelay: enterDelay)
        } catch {
            sendError = "Couldn't send to \(name): \(error)"
            return
        }
        if generation == loadGeneration {
            let now = Date()
            for i in record.issues.indices where draft.issueIDs.contains(record.issues[i].id) {
                record.issues[i].sentTo = name
                record.issues[i].sentAt = now
                record.issues[i].status = .inProgress
            }
            for i in record.comments.indices where draft.commentIDs.contains(record.comments[i].id) {
                record.comments[i].sentTo = name
                record.comments[i].sentAt = now
            }
            persist()
        }
        sendDraft = nil
        sendError = nil
        let count = draft.issueIDs.count + draft.commentIDs.count
        toast("Sent \(count) item\(count == 1 ? "" : "s") to \(name)")
    }
}
