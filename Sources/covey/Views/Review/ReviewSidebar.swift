import SwiftUI
import CoveyGit

struct ReviewSidebar: View {
    @Bindable var model: ReviewModel
    let tk: Tokens

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tab(.files, "Files", model.files.count)
                tab(.issues, "Issues", model.record.issues.filter { $0.status.isActive }.count)
                Spacer()
            }
            .padding(.horizontal, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(tk.bd2).frame(height: 1) }
            switch model.sidebarTab {
            case .files: ReviewFilesTab(model: model, tk: tk)
            case .issues: ReviewIssuesTab(model: model, tk: tk)
            }
        }
        .frame(width: 296)
        .background(tk.surface)
        .overlay(alignment: .trailing) { Rectangle().fill(tk.bd2).frame(width: 1) }
    }

    private func tab(_ tab: SidebarTab, _ title: String, _ count: Int) -> some View {
        Button { model.sidebarTab = tab } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text("\(count)").font(ReviewFont.mono(10.5)).foregroundStyle(tk.t3)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .foregroundStyle(model.sidebarTab == tab ? tk.t1 : tk.t3)
            .overlay(alignment: .bottom) {
                Rectangle().fill(model.sidebarTab == tab ? tk.t1 : Color.clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ReviewFilesTab: View {
    @Bindable var model: ReviewModel
    let tk: Tokens

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Filter by path", text: $model.filter.query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                HStack(spacing: 4) {
                    ForEach(FileStatus.allCases, id: \.self) { status in
                        ReviewChip(label: status.rawValue, on: model.filter.statuses.contains(status), tk: tk) {
                            if model.filter.statuses.contains(status) {
                                model.filter.statuses.remove(status)
                            } else {
                                model.filter.statuses.insert(status)
                            }
                        }
                    }
                }
                HStack(spacing: 4) {
                    ReviewChip(label: "Unreviewed", on: model.filter.unreviewedOnly, tk: tk) {
                        model.filter.unreviewedOnly.toggle()
                    }
                    ReviewChip(label: "Has issues", on: model.filter.withIssuesOnly, tk: tk) {
                        model.filter.withIssuesOnly.toggle()
                    }
                    ReviewChip(label: "Changed", on: model.filter.changedOnly, tk: tk) {
                        model.filter.changedOnly.toggle()
                    }
                }
            }
            .padding(12)
            Rectangle().fill(tk.bd2).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.treeRows) { row in ReviewTreeRowView(row: row, model: model, tk: tk) }
                }
                .padding(.vertical, 6)
            }
            Rectangle().fill(tk.bd2).frame(height: 1)
            HStack(spacing: 12) {
                Text("○ unread").foregroundStyle(ReviewGlyph.unread.color(tk))
                Text("◐ reviewing").foregroundStyle(ReviewGlyph.reviewing.color(tk))
                Text("✓ reviewed").foregroundStyle(ReviewGlyph.reviewed.color(tk))
                Text("! issues").foregroundStyle(ReviewGlyph.issues.color(tk))
            }
            .font(.system(size: 11))
            .padding(.horizontal, 14)
            .frame(height: 32)
        }
    }
}

private struct ReviewTreeRowView: View {
    let row: FileTreeRow
    @Bindable var model: ReviewModel
    let tk: Tokens

    var body: some View {
        HStack(spacing: 6) {
            switch row.kind {
            case .directory(_, let expanded):
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(tk.t3)
                    .frame(width: 10)
                Text(row.name).font(.system(size: 12.5)).foregroundStyle(tk.t2)
                Spacer()
            case .file(let file):
                let glyph = ReviewGlyph.of(model.review(for: file.path), hasOpenIssues: model.hasOpenIssues(file.path))
                let issues = model.openIssueCount(file.path)
                Circle().fill(file.status.color(tk)).frame(width: 6, height: 6).frame(width: 10)
                Text(row.name)
                    .font(ReviewFont.mono(12))
                    .foregroundStyle(tk.t1)
                    .strikethrough(file.status == .deleted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let added = file.added, added > 0 {
                    Text("+\(added)").font(ReviewFont.mono(10.5)).foregroundStyle(tk.diffAdd)
                }
                if let removed = file.removed, removed > 0 {
                    Text("−\(removed)").font(ReviewFont.mono(10.5)).foregroundStyle(tk.diffDel)
                }
                if issues > 0 {
                    Text("\(issues)").font(ReviewFont.mono(10.5)).foregroundStyle(tk.err)
                }
                Text(glyph.symbol).font(.system(size: 11)).foregroundStyle(glyph.color(tk)).frame(width: 12)
            }
        }
        .padding(.leading, 12 + CGFloat(row.depth) * 14)
        .padding(.trailing, 12)
        .frame(height: 26)
        .background(isSelected ? tk.cardHover : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            switch row.kind {
            case .directory(let path, _): model.toggleDirectory(path)
            case .file(let file): Task { await model.select(file.path) }
            }
        }
    }

    private var isSelected: Bool {
        if case .file(let file) = row.kind { return model.selectedPath == file.path }
        return false
    }
}

private struct ReviewIssuesTab: View {
    @Bindable var model: ReviewModel
    let tk: Tokens

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Issues", selection: $model.issueFilter) {
                    ForEach(IssueListFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
                Spacer()
                ReviewButton(title: "Send review · \(model.unsentCount)",
                             prominent: model.unsentCount > 0, tk: tk) { model.beginSend() }
                    .disabled(model.unsentCount == 0)
            }
            .padding(12)
            Rectangle().fill(tk.bd2).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.visibleIssues) { issue in ReviewIssueRow(issue: issue, model: model, tk: tk) }
                    if model.visibleIssues.isEmpty {
                        Text("No issues in this filter.")
                            .font(.system(size: 12))
                            .foregroundStyle(tk.t3)
                            .padding(14)
                    }
                }
            }
        }
    }
}

private struct ReviewIssueRow: View {
    let issue: ReviewIssue
    @Bindable var model: ReviewModel
    let tk: Tokens

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("#\(issue.id)").font(ReviewFont.mono(11)).foregroundStyle(tk.t3)
                Text(issue.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tk.t1)
                    .strikethrough(issue.status == .dismissed)
                Spacer(minLength: 6)
                Text(issue.severity.rawValue.uppercased())
                    .font(ReviewFont.caption(10))
                    .foregroundStyle(issue.severity.color(tk))
            }
            Text(ReviewPrompt.location(issue.anchor)).font(ReviewFont.mono(11)).foregroundStyle(tk.t2)
            if let note = issue.note {
                Text(note).font(.system(size: 11.5))
                    .foregroundStyle(issue.anchorState == .tracked ? tk.t3 : tk.warn)
            }
            HStack(spacing: 6) {
                Text(issue.status.rawValue)
                    .font(.system(size: 11))
                    .foregroundStyle(issue.status.color(tk))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.rSm).stroke(tk.bd3))
                Spacer()
                if issue.status == .open {
                    ReviewButton(title: "Send →", tk: tk) { model.beginSend(issue: issue.id) }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.selectedPath == issue.anchor.path ? tk.cardHover : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(tk.bd2).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { Task { await model.openIssue(issue.id) } }
        .opacity(issue.status.isActive ? 1 : 0.6)
    }
}
