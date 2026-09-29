import SwiftUI
import CoveyGit
import CoveyKit

enum ReviewFont {
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Small-caps-like labels: "ISSUE #3", "COMPARISON".
    static func caption(_ size: CGFloat = 10.5) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
}

extension FileStatus {
    var label: String {
        switch self {
        case .added: return "ADDED"
        case .modified: return "MODIFIED"
        case .deleted: return "DELETED"
        case .renamed: return "RENAMED"
        }
    }

    func color(_ tk: Tokens) -> Color {
        switch self {
        case .added: return tk.diffAdd
        case .modified: return tk.warn
        case .deleted: return tk.diffDel
        case .renamed: return tk.t2
        }
    }
}

extension ReviewGlyph {
    func color(_ tk: Tokens) -> Color {
        switch self {
        case .unread: return tk.t4
        case .reviewing: return tk.warn
        case .reviewed: return tk.diffAdd
        case .issues: return tk.err
        }
    }
}

extension IssueSeverity {
    func color(_ tk: Tokens) -> Color {
        switch self {
        case .high: return tk.err
        case .medium: return tk.warn
        case .low: return tk.t2
        }
    }
}

extension IssueStatus {
    func color(_ tk: Tokens) -> Color {
        switch self {
        case .open: return tk.err
        case .inProgress: return tk.warn
        case .resolved: return tk.ok
        case .dismissed: return tk.t4
        }
    }
}

extension FileReviewState {
    var label: String {
        switch self {
        case .unread: return "Unread"
        case .reviewing: return "Reviewing"
        case .reviewed: return "Reviewed"
        }
    }
}

func reviewStatusColor(_ status: Status?, _ tk: Tokens) -> Color {
    switch status {
    case .running: return tk.run
    case .waiting: return tk.wait
    case .idle: return tk.ok
    case nil: return tk.t4
    }
}

/// The window's bordered button; `prominent` inverts it for the main action.
struct ReviewButton: View {
    let title: String
    var hint: String?
    var prominent = false
    let tk: Tokens
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let hint { Text(hint).font(ReviewFont.mono(10)).opacity(0.7) }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .foregroundStyle(prominent ? tk.bg : tk.t1)
            .background(prominent ? tk.t1 : tk.surf2)
            .overlay(RoundedRectangle(cornerRadius: Tokens.rSm).stroke(prominent ? tk.t1 : tk.bd3))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.rSm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ReviewChip: View {
    let label: String
    let on: Bool
    let tk: Tokens
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .foregroundStyle(on ? tk.bg : tk.t2)
                .background(on ? tk.t2 : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: Tokens.rSm).stroke(tk.bd3))
                .clipShape(RoundedRectangle(cornerRadius: Tokens.rSm))
        }
        .buttonStyle(.plain)
    }
}

struct ReviewEmptyState<Action: View>: View {
    let title: String
    let message: String
    let tk: Tokens
    let action: Action

    init(title: String, message: String, tk: Tokens, @ViewBuilder action: () -> Action) {
        self.title = title
        self.message = message
        self.tk = tk
        self.action = action()
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(tk.t1)
            Text(message).font(.system(size: 12.5)).foregroundStyle(tk.t3)
                .multilineTextAlignment(.center)
            action
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension ReviewEmptyState where Action == EmptyView {
    init(title: String, message: String, tk: Tokens) {
        self.init(title: title, message: message, tk: tk) { EmptyView() }
    }
}
