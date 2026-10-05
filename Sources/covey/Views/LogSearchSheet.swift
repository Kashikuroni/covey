import AppKit
import CoveyKit
import SwiftUI

/// Live-grep over the app's log directory (`LogPaths.directory`), Telescope-
/// style: type and results refine as you go, newest file and newest line
/// first. The query is a case-insensitive regex; an invalid pattern degrades
/// to a literal search. Read-only — debugging aid; `c` copies the selected
/// line as `file:line: text`.
struct LogSearchSheet: View {
    let model: AppModel
    @State private var query = ""
    @State private var files: [(name: String, content: String)] = []
    @State private var selected = 0
    @State private var selectedFile: String?          // nil = all files
    @State private var pickerOpen = false
    @State private var pickerQuery = ""
    @State private var pickerSelected = 0             // 0 = "All files"
    @FocusState private var searchFocused: Bool
    @FocusState private var pickerFocused: Bool

    private var tk: Tokens { Tokens(Theme(raw: model.themeRaw)) }
    private var scopedFiles: [(name: String, content: String)] {
        guard let selectedFile else { return files }
        return files.filter { $0.name == selectedFile }
    }
    private var hits: [LogLine] { searchLogs(files: scopedFiles, query: query) }
    private var pickerRows: [String?] {
        [nil] + filterLogNames(files.map(\.name), query: pickerQuery)   // nil = All
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Search app logs").font(.headline)
                Spacer()
                filePicker
            }
            TextField("regex, e.g. rpcError|parseFail — invalid falls back to literal",
                      text: $query)
                .focused($searchFocused)
                .ayuField(tk, focused: searchFocused)
                .onKeyPress(.downArrow) { step(1); return .handled }
                .onKeyPress(.upArrow) { step(-1); return .handled }
                .onKeyPress(.return, phases: .down) { _ in
                    copySelected(); return .handled
                }
            resultsList
            HStack(spacing: 10) {
                KbdBadge(key: "↑↓", label: "move", tk: tk)
                KbdBadge(key: "enter/c", label: "copy", tk: tk)
                KbdBadge(key: "r", label: "reload", tk: tk)
                KbdBadge(key: "f", label: "file", tk: tk)
                Spacer()
                Text("\(hits.count) line\(hits.count == 1 ? "" : "s") · \(files.count) file\(files.count == 1 ? "" : "s")")
                    .font(.caption2).monospaced().foregroundStyle(tk.t4)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .focusEffectDisabled()
        .onExitCommand {
            if pickerOpen { closePicker() } else { model.modal = nil }
        }
        .onAppear { searchFocused = true; reload() }
    }

    // MARK: file dropdown

    private var filePicker: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                openPicker()
            } label: {
                HStack(spacing: 4) {
                    Text(selectedFile ?? "All files")
                        .lineLimit(1)
                    Text("▾").foregroundStyle(tk.t4)
                }
                .font(.caption.monospaced())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .frame(width: 200)
            }
            .buttonStyle(.plain)
            .background(tk.card, in: RoundedRectangle(cornerRadius: Tokens.r))
            .overlay(RoundedRectangle(cornerRadius: Tokens.r)
                .strokeBorder(pickerOpen ? tk.bd3 : tk.bd))
            if pickerOpen { pickerList }
        }
    }

    private var pickerList: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("filter files", text: $pickerQuery)
                .focused($pickerFocused)
                .ayuField(tk, focused: pickerFocused)
                .onKeyPress(.downArrow) { pickerStep(1); return .handled }
                .onKeyPress(.upArrow) { pickerStep(-1); return .handled }
                .onKeyPress(.return, phases: .down) { _ in
                    commitPicker(); return .handled
                }
                .onKeyPress(.tab) { commitPicker(); return .handled }
            ForEach(Array(pickerRows.enumerated()), id: \.offset) { idx, name in
                HStack {
                    Text(name ?? "All files")
                    Spacer()
                }
                .font(.caption.monospaced())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(idx == pickerSelected
                            ? Color.accentColor.opacity(0.2) : .clear)
                .contentShape(Rectangle())
                .onTapGesture { pickerSelected = idx; commitPicker() }
            }
        }
        .padding(6)
        .frame(width: 200)
        .background(tk.surface, in: RoundedRectangle(cornerRadius: Tokens.r))
        .overlay(RoundedRectangle(cornerRadius: Tokens.r).strokeBorder(tk.bd3))
        .zIndex(2)
    }

    private func openPicker() {
        pickerQuery = ""
        pickerSelected = 0
        pickerOpen = true
        pickerFocused = true
    }

    private func closePicker() {
        pickerOpen = false
        pickerQuery = ""
        searchFocused = true
    }

    private func commitPicker() {
        selectedFile = pickerRows.indices.contains(pickerSelected)
            ? pickerRows[pickerSelected] : nil
        closePicker()
    }

    private func pickerStep(_ delta: Int) {
        let count = pickerRows.count
        guard count > 0 else { return }
        pickerSelected = ((pickerSelected + delta) % count + count) % count
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            SubduedScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if hits.isEmpty {
                        Text(files.isEmpty
                             ? "no logs in \(collapseHome(LogPaths.directory))"
                             : "no matches")
                            .font(.caption).foregroundStyle(tk.t4)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                    ForEach(Array(hits.enumerated()), id: \.offset) { idx, hit in
                        LogLineRow(hit: hit, current: idx == selected, tk: tk)
                            .id(idx)
                            .contentShape(Rectangle())
                            .onTapGesture { selected = idx }
                    }
                }
            }
            .focusable()
            .onChange(of: selected) { _, idx in
                withAnimation(.easeOut(duration: 0.08)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
            .onKeyPress(phases: .down) { press in
                switch latinize(press.characters.first ?? " ") {
                case "j": step(1); return .handled
                case "k": step(-1); return .handled
                case "c": copySelected(); return .handled
                case "r": reload(); return .handled
                case "f": openPicker(); return .handled
                case "/": searchFocused = true; return .handled
                default: return .ignored
                }
            }
        }
    }

    /// Selection stays anchored while the result set shrinks/grows under the
    /// cursor (live-typing keeps 0 = newest).
    private func step(_ delta: Int) {
        guard !hits.isEmpty else { selected = 0; return }
        selected = ((selected + delta) % hits.count + hits.count) % hits.count
    }

    private func copySelected() {
        guard hits.indices.contains(selected) else { return }
        let hit = hits[selected]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(hit.file):\(hit.line): \(hit.text)",
                                       forType: .string)
    }

    private func reload() {
        files = logFiles(in: LogPaths.directory)
            .map { (name: ($0 as NSString).lastPathComponent, content: readLogFile($0)) }
        // Keep the file filter across reloads (rotation moves usage.log to
        // usage.log.1); a vanished file quietly resets to "All".
        if let file = selectedFile, !files.contains(where: { $0.name == file }) {
            selectedFile = nil
        }
        selected = 0
    }
}

private struct LogLineRow: View {
    let hit: LogLine
    let current: Bool
    let tk: Tokens

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(hit.file):\(hit.line)")
                .font(.caption.monospaced())
                .foregroundStyle(tk.t4)
                .frame(width: 150, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.head)
            Text(hit.text)
                .font(.caption.monospaced())
                .foregroundStyle(current ? tk.t1 : tk.t2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(current ? tk.cardHover : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(current ? tk.t1 : .clear)
                .frame(width: 2)
        }
    }
}
