import SwiftUI
import AppKit
import CoveyKit

/// Issue tab router: the browser (list/detail/edit) or the composer.
/// Keyboard-first: the list owns plain vim keys via .onKeyPress — the
/// ContentView monitor passes inspector plain keys through (see the
/// "inspector zone owns its plain keys" branch).
struct IssueBrowserPane: View {
    @Bindable var model: AppModel
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool
    @FocusState private var detailFocused: Bool
    @State private var searchVisible = false

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }
    private var browser: IssueBrowserModel { model.issueBrowser }
    private var root: String? { model.sessionRootOfSelected() }

    var body: some View {
        Group {
            if root == nil {
                Text("select a session in a git repo")
                    .font(.system(size: IssueFont.body)).foregroundStyle(tk.t4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.issueScreen == .composer {
                IssuePane(model: model)
                    .onExitCommand { backToBrowser() }
            } else {
                browserBody
            }
        }
        .onAppear {
            // Fresh mount can miss the deferred focus tick; data must not ride on
            // runloop ordering — self-open when nothing was ever loaded.
            if model.issueScreen == .browser, browser.stage == .idle { openList() }
        }
        .onChange(of: model.issueFocusTick) { _, _ in
            guard model.issueScreen == .browser else { return }
            openList()
        }
        .onChange(of: root) { _, newRoot in
            guard model.issueScreen == .browser else { return }
            guard let newRoot else { return }   // nil root: pane already shows the hint
            // A detail/edit screen from the old repo must not survive the switch.
            browser.screen = .list
            if let dir = model.inspectorDir {
                Task { await browser.open(root: newRoot, dir: dir) }
            }
        }
        .onChange(of: browser.screen) { _, newScreen in
            // Every road back to the list must hand it the keyboard — incl.
            // the vanished-issue fallback (close drops the issue from the
            // open filter) and deleteConfirmed's model-side return, which
            // never pass through the pane's key handlers. Deferred a turn:
            // the rows remount in this same transaction (the focus-tick
            // lesson — a same-transaction FocusState write can be lost).
            guard newScreen == .list, model.issueScreen == .browser else { return }
            Task { @MainActor in listFocused = true }
        }
    }

    private func backToBrowser() {
        model.setIssueScreen(.browser)
        openList()
    }

    private func openList() {
        if let root, let dir = model.inspectorDir {
            Task { await browser.open(root: root, dir: dir) }
        }
        // Deferred a turn: returning from the composer, the list rows remount in
        // this same transaction, and a same-transaction FocusState write is lost
        // (the focus-tick lesson) — which left j/k dead. Focus once mounted.
        Task { @MainActor in listFocused = true }
    }

    @ViewBuilder
    private var browserBody: some View {
        switch browser.screen {
        case .list: listScreen
        case .detail(let n):
            if let issue = browser.issues.first(where: { $0.number == n }) {
                detailScreen(issue)
            } else {
                // The issue vanished on a refetch — fall back to the list.
                Color.clear.onAppear { browser.screen = .list }
            }
        case .edit(let n):
            if let issue = browser.issues.first(where: { $0.number == n }) {
                IssueEditView(model: model, issue: issue)
                    .id(n)   // fresh @State per issue
            } else {
                Color.clear.onAppear { browser.screen = .list }
            }
        }
    }

    // MARK: - detail

    private func detailScreen(_ issue: GhIssue) -> some View {
        let hasSession = sessionForIssue(issue) != nil || recentForIssue(issue) != nil
        return VStack(alignment: .leading, spacing: 6) {
            bindingRow(issue)
            IssueDetailView(issue: issue, tk: tk)
            if let prompt = browser.prompt { promptCard(prompt) }
            HStack(spacing: 10) {
                KbdBadge(key: "e", label: "edit", tk: tk)
                KbdBadge(key: "s", label: hasSession ? "open" : "session", tk: tk)
                KbdBadge(key: "c", label: issue.isOpen ? "close" : "reopen", tk: tk)
                KbdBadge(key: "x", label: "delete", tk: tk)
                KbdBadge(key: "b", label: "browser", tk: tk)
                KbdBadge(key: "esc", label: "list", tk: tk)
            }
        }
        .padding(8)
        .focusable()
        .focused($detailFocused)
        .onKeyPress(phases: .down) { press in handleDetailKey(press) }
        .onAppear { detailFocused = true }   // screen switch = explicit user action
        .onExitCommand {
            browser.screen = .list
            listFocused = true
        }
    }

    /// Header cue: the session (live or stopped) and branch this issue is
    /// bound to, when any exists.
    @ViewBuilder
    private func bindingRow(_ issue: GhIssue) -> some View {
        let live = sessionForIssue(issue)
        let recent = live == nil ? recentForIssue(issue) : nil
        let branch = boundBranch(issue)
        if live != nil || recent != nil || branch != nil {
            HStack(spacing: 8) {
                if let live {
                    bindingTag("session", live.name, tk.ok)
                } else if let recent {
                    bindingTag("recent", recent.name, tk.t3)
                }
                if let branch { bindingTag("branch", branch, tk.accent) }
                Spacer()
            }
        }
    }

    private func bindingTag(_ key: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: IssueFont.meta)).foregroundStyle(tk.t4)
            Text(value).font(.system(size: IssueFont.meta, design: .monospaced))
                .foregroundStyle(tint).lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(tk.surf2, in: Capsule())
        .overlay(Capsule().strokeBorder(tk.bd2))
    }

    private func handleDetailKey(_ press: KeyPress) -> KeyPress.Result {
        if browser.prompt != nil { return handlePromptKey(press) }
        if press.key == .escape {
            browser.screen = .list
            listFocused = true
            return .handled
        }
        guard let raw = press.characters.first else { return .ignored }
        return handleActionKey(latinize(raw))
    }

    // MARK: - list

    private var listScreen: some View {
        VStack(alignment: .leading, spacing: 6) {
            if searchVisible { searchField }
            listBody
            if let prompt = browser.prompt { promptCard(prompt) }   // inline close/delete prompt
            Spacer(minLength: 0)
            footerHints
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        TextField("fuzzy filter", text: Binding(
            get: { browser.query }, set: { browser.query = $0 }))
            .focused($searchFocused)
            .ayuField(tk, focused: searchFocused)
            .onSubmit { searchFocused = false; listFocused = true }
            .onExitCommand {
                browser.query = ""
                searchVisible = false
                searchFocused = false
                listFocused = true
            }
    }

    @ViewBuilder
    private var listBody: some View {
        switch browser.stage {
        case .idle, .loading:
            statusCard(tk: tk, tint: tk.wait, title: "loading issues…", spinner: true) {
                EmptyView()
            }
        case .failed(let msg):
            statusCard(tk: tk, icon: "xmark", tint: tk.err, title: "gh failed") {
                Text(msg).font(.system(size: IssueFont.meta, design: .monospaced)).foregroundStyle(tk.t2)
                    .textSelection(.enabled).lineLimit(8)
            }
        case .ready:
            if let note = browser.staleNote {
                Text(note).font(.system(size: IssueFont.meta)).foregroundStyle(tk.warn)
            }
            if browser.visible().isEmpty {
                let text = browser.stateFilter == .all
                    ? "no issues" : "no \(browser.stateFilter.rawValue) issues"
                Text(text)
                    .font(.system(size: IssueFont.body)).foregroundStyle(tk.t4)
            } else {
                rows
            }
        }
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            SubduedScrollView {
                VStack(spacing: 9) {
                    ForEach(browser.visible(), id: \.number) { issue in
                        row(issue)
                            .id(issue.number)
                    }
                }
            }
            .onChange(of: browser.selectedNumber) { _, n in
                if let n { proxy.scrollTo(n) }
            }
        }
        .focusable()
        .focused($listFocused)
        .onKeyPress(phases: .down) { press in handleListKey(press) }
    }

    private func row(_ issue: GhIssue) -> some View {
        IssueCardView(issue: issue,
                      selected: issueCardIsHighlighted(
                        selected: issue.number == browser.selectedNumber,
                        inspectorFocused: model.focus == .inspector),
                      age: relativeAge(from: issue.updatedAt, to: browser.now()),
                      wip: wip(for: issue),
                      tk: tk,
                      onSessionTap: { jumpToSession(of: issue) })
            .contentShape(Rectangle())
            .onTapGesture {
                model.setFocus(.inspector)
                browser.selectNumber(issue.number)
                listFocused = true
            }
    }

    /// WIP signals for one row: live covey session in this root, first
    /// matching local branch, first linked PR.
    private func wip(for issue: GhIssue) -> IssueWip {
        let session = sessionForIssue(issue)
        return IssueWip(
            sessionName: session?.name,
            sessionTint: session.map {
                sessionStatusTint(model.statusByName[$0.name] ?? .idle, tk: tk)
            },
            branch: session?.git?.branch ?? browser.localBranches.first {
                branchMatchesIssue($0, number: issue.number)
            },
            added: session?.git?.added,
            removed: session?.git?.removed,
            prNumber: issue.linkedPRs.first?.number)
    }

    private func sessionForIssue(_ issue: GhIssue) -> Session? {
        guard let root else { return nil }
        // Stored binding first (survives rename); fall back to the "#N" name
        // convention for sessions created before the binding existed.
        return model.sessions.first {
            sessionRoot($0) == root
                && (model.issueNumber(forSession: $0.name) == issue.number
                    || sessionNameMatchesIssue($0.name, number: issue.number))
        }
    }

    /// A stopped (recent) session bound to the issue — relaunchable to resume.
    private func recentForIssue(_ issue: GhIssue) -> RecentSession? {
        model.visibleRecents().first {
            model.issueNumber(forSession: $0.name) == issue.number
                || sessionNameMatchesIssue($0.name, number: issue.number)
        }
    }

    /// The issue's local branch, if one exists — the "create in this branch" cue.
    private func boundBranch(_ issue: GhIssue) -> String? {
        browser.localBranches.first { branchMatchesIssue($0, number: issue.number) }
    }

    private func jumpToSession(of issue: GhIssue) {
        guard let session = sessionForIssue(issue) else { return }
        Task { @MainActor in
            await model.select(session.name)
            model.perform(.focusAgent)
        }
    }

    private func handleListKey(_ press: KeyPress) -> KeyPress.Result {
        if browser.prompt != nil { return handlePromptKey(press) }   // inline close/delete prompt
        if press.key == .escape { return .ignored }   // zone exit stays global
        if press.key == .downArrow { browser.moveSelection(1); return .handled }
        if press.key == .upArrow { browser.moveSelection(-1); return .handled }
        if press.key == .return {
            if let n = browser.selectedNumber { browser.screen = .detail(n) }
            return .handled
        }
        guard let raw = press.characters.first else { return .ignored }
        switch latinize(raw) {
        case "j": browser.moveSelection(1); return .handled
        case "k": browser.moveSelection(-1); return .handled
        case "/":
            searchVisible = true
            searchFocused = true
            return .handled
        case "o":
            Task { await browser.cycleFilter() }
            return .handled
        case "r":
            Task { await browser.refresh(force: true) }
            return .handled
        case "n":
            model.setIssueScreen(.composer)
            model.activateIssues()   // bumps issueFocusTick -> title focus
            return .handled
        default:
            return handleActionKey(latinize(raw))   // s/e/c/x/b — Tasks 12-14
        }
    }

    /// Shared by list and detail screens: `s`/`b`/`e` act on the current
    /// selection; `c` opens the close-reason prompt (or reopens directly on
    /// a closed issue); `x` opens the delete-confirm prompt.
    private func handleActionKey(_ ch: Character) -> KeyPress.Result {
        guard let issue = browser.selectedIssue() else { return .ignored }
        switch ch {
        case "s":
            // Smart: jump to a live bound session, relaunch a stopped one
            // (resumes its conversation), or open the form only if none exists —
            // preselecting the issue's branch when there is one.
            if sessionForIssue(issue) != nil {
                jumpToSession(of: issue)
            } else if let recent = recentForIssue(issue) {
                Task { await model.relaunchRecent(recent) }
            } else {
                model.newSessionFromIssue(number: issue.number, title: issue.title,
                                          branch: boundBranch(issue))
            }
            return .handled
        case "b":
            if let url = URL(string: issue.url) { NSWorkspace.shared.open(url) }
            return .handled
        case "e":
            browser.screen = .edit(issue.number)
            return .handled
        case "c":
            if issue.isOpen {
                browser.beginClose()
            } else {
                Task { await browser.reopenSelected() }
            }
            return .handled
        case "x":
            browser.beginDelete()
            return .handled
        case "g":
            guard sessionForIssue(issue) != nil else { return .ignored }
            jumpToSession(of: issue)
            return .handled
        default:
            return .ignored
        }
    }

    private func handlePromptKey(_ press: KeyPress) -> KeyPress.Result {
        guard !browser.actionBusy else { return .handled }   // swallow while running
        if press.key == .escape {
            browser.cancelPrompt()
            return .handled
        }
        switch browser.prompt {
        case .closeReason:
            guard let raw = press.characters.first else { return .handled }
            switch Character(latinize(raw).lowercased()) {
            case "c": Task { await browser.closeSelected(reason: .completed) }
            case "n": Task { await browser.closeSelected(reason: .notPlanned) }
            default: break
            }
            return .handled
        case .deleteConfirm:
            if press.key == .return {
                Task { await browser.deleteConfirmed() }
            }
            return .handled
        case nil:
            return .ignored
        }
    }

    @ViewBuilder
    private func promptCard(_ prompt: IssueBrowserModel.Prompt) -> some View {
        switch prompt {
        case .closeReason(let n):
            statusCard(tk: tk, tint: tk.wait, title: "close #\(n)",
                       spinner: browser.actionBusy) {
                HStack(spacing: 10) {
                    KbdBadge(key: "c", label: "completed", tk: tk)
                    KbdBadge(key: "n", label: "not planned", tk: tk)
                    KbdBadge(key: "esc", label: "cancel", tk: tk)
                }
            }
        case .deleteConfirm(let n):
            statusCard(tk: tk, icon: "trash", tint: tk.err, title: "delete issue #\(n)?",
                       spinner: browser.actionBusy) {
                HStack(spacing: 10) {
                    KbdBadge(key: "enter", label: "delete", tk: tk)
                    KbdBadge(key: "esc", label: "cancel", tk: tk)
                }
            }
        }
    }

    private var footerHints: some View {
        HStack(spacing: 10) {
            KbdBadge(key: "enter", label: "view", tk: tk)
            KbdBadge(key: "n", label: "new", tk: tk)
            KbdBadge(key: "s", label: "session", tk: tk)
            KbdBadge(key: "/", label: "search", tk: tk)
        }
    }
}
