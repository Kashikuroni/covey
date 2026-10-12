import SwiftUI
import CoveyKit

struct DocumentPaneView: View {
    let reader: DocumentReaderModel
    let zone: PersistedDocumentZone
    let model: AppModel
    let viewID: ViewID
    let onClose: () -> Void
    @State private var presentation: DocumentPresentation?
    @State private var command: DocumentRenderCommand?
    @State private var showingOutline = false
    @State private var showingFind = false
    @State private var query = ""
    @State private var found = (current:0,total:0)
    @State private var linkError: String?
    @FocusState private var findFocused: Bool
    private var tk: Tokens { Tokens(Theme(raw:model.themeRaw)) }
    private var renderKey: String { "\(reader.current?.path ?? ""):\(reader.revision):\(zone.sourceMode)" }
    var body: some View {
        VStack(spacing:0) {
            VStack(alignment:.leading,spacing:5) {
                HStack {
                    Text("Documents").font(.caption.weight(.semibold)).foregroundStyle(model.focus == .documents ? tk.accent : tk.t2)
                    Spacer()
                    Text("Read only").font(.caption).foregroundStyle(tk.t2)
                }
                Text(reader.current?.path ?? "Project document").font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    .help("\(reader.current?.path ?? "")\n\(zone.context.sourceSession) · \(zone.context.root)")
                Text("\(zone.context.sourceSession) · \(zone.context.root)").font(.caption).foregroundStyle(tk.t2).lineLimit(1).truncationMode(.middle)
                HStack(spacing:10) {
                    icon("chevron.left","Back",disabled:!reader.canGoBack) { Task { await reader.goBack() } }
                    icon("chevron.right","Forward",disabled:!reader.canGoForward) { Task { await reader.goForward() } }
                    icon("doc.text.magnifyingglass","Open project document") { Task { await model.openDocumentPicker() } }
                    icon("list.bullet","Outline",disabled:presentation?.headings.isEmpty != false) { showingOutline.toggle() }
                        .popover(isPresented:$showingOutline) {
                            ScrollView {
                                VStack(alignment:.leading,spacing:4) {
                                    ForEach(presentation?.headings ?? []) { heading in
                                        Button(heading.text) { command = .init(action:.revealAnchor(heading.id)); showingOutline = false }
                                            .buttonStyle(.plain).padding(.leading,CGFloat(max(0,heading.level-1))*12).padding(.vertical,4)
                                    }
                                }.padding(12).frame(width:280,alignment:.leading)
                            }.frame(maxHeight:360)
                        }
                    icon("magnifyingglass","Find in document") { showingFind = true; findFocused = true }
                    Button(zone.sourceMode ? "Rendered" : "Source") { model.setDocumentSourceMode(!zone.sourceMode,viewID:viewID) }
                        .buttonStyle(.plain).font(.caption).help("Toggle Markdown source")
                    Spacer(minLength:0)
                    icon("xmark","Close document view",action:onClose)
                }
            }.padding(.horizontal,12).padding(.top,Tokens.paneHeaderTop).padding(.bottom,10)
            if showingFind {
                HStack(spacing:6) {
                    TextField("Find in document",text:$query).focused($findFocused)
                        .onChange(of:query) { _,value in command = .init(action:.find(query:value,backwards:false)) }
                        .onSubmit { command = .init(action:.find(query:query,backwards:false)) }
                    Text("\(found.current)/\(found.total)").font(.caption.monospacedDigit()).foregroundStyle(tk.t2)
                    icon("chevron.up","Previous match") { command = .init(action:.find(query:query,backwards:true)) }
                    icon("chevron.down","Next match") { command = .init(action:.find(query:query,backwards:false)) }
                    icon("xmark","Close find",action:closeFind)
                }.padding(8).background(tk.surf2)
                    .onKeyPress(.escape) { closeFind(); return .handled }
            }
            if let error = reader.error ?? linkError {
                HStack {
                    Text(error).font(.caption).foregroundStyle(tk.err)
                    Spacer()
                    Button("Retry") { linkError = nil; Task { await reader.refresh() } }
                }.padding(10)
            }
            if reader.loading { ProgressView().controlSize(.small).padding(4) }
            content
        }
        .foregroundStyle(tk.t1)
        .panelCard(tk,surface:tk.termBg)
        .simultaneousGesture(TapGesture().onEnded { model.setFocus(.documents) })
        .task(id:renderKey) {
            if case .text(let path,let text,let markdown,_) = reader.snapshot {
                presentation = .init(text:text,path:path,context:reader.context,sourceMode:zone.sourceMode || !markdown)
                if let fragment = reader.current?.fragment { command = .init(action:.revealAnchor(fragment)) }
                else if let position = reader.current?.position { command = .init(action:.restore(position)) }
            } else { presentation = nil }
        }
        .onChange(of:model.focus) { _,focus in if focus == .documents, !findFocused { command = .init(action:.focus) } }
        .onChange(of:model.showDashboardSettings) { _,shown in if !shown, model.focus == .documents, model.modal == nil { command = .init(action:.focus) } }
        .onChange(of:model.documentFindRequest) { _,_ in if model.activeViewID == viewID { showingFind = true; findFocused = true } }
    }
    @ViewBuilder private var content: some View {
        if let presentation, let error = presentation.error {
            message("Couldn’t render document",detail:error)
        } else if let presentation {
            DocumentRenderedView(presentation:presentation,command:command,position:reader.current?.position,
                                 fragment:reader.current?.fragment,theme:Theme(raw:model.themeRaw),onEvent:handle)
        } else if let snapshot = reader.snapshot {
            switch snapshot {
            case .binary(_,let count): message("Binary file",detail:"\(count.formatted()) bytes · Preview isn’t available for this file type.")
            case .tooLarge(_,let count): message("File is too large to preview",detail:"\(count.formatted()) bytes · The preview limit is 4 MB.")
            case .text: Spacer()
            }
        } else { message(reader.loading ? "Loading document…" : "Document unavailable",detail:"\(zone.context.root)") }
    }
    private func message(_ title: String, detail: String) -> some View {
        VStack(spacing:8) { Spacer(); Text(title).font(.headline); Text(detail).font(.callout).foregroundStyle(tk.t2).textSelection(.enabled); Spacer() }.padding(20).frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private func icon(_ symbol: String, _ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action:action) { Image(systemName:symbol).frame(width:18,height:20) }.buttonStyle(.plain).help(title).accessibilityLabel(title).disabled(disabled)
    }
    private func closeFind() { showingFind = false; query = ""; findFocused = false; command = .init(action:.find(query:"",backwards:false)) }
    private func handle(_ event: DocumentRenderEvent) {
        switch event {
        case .position(let position): reader.recordPosition(position)
        case .findResult(let current,let total): found = (current,total)
        case .ready: if model.focus == .documents, !findFocused { command = .init(action:.focus) }
        case .focused: model.setFocus(.documents)
        case .link(let reference):
            do {
                switch try DocumentLinkResolver.resolve(reference,from:reader.current?.path ?? "",context:reader.context) {
                case .web(let url): NSWorkspace.shared.open(url)
                case .local(let path,let fragment):
                    linkError = nil
                    Task { await reader.open(.init(path:path,fragment:fragment)); model.recordDocumentRecent(path:path,root:reader.context.root) }
                }
            } catch { linkError = error.localizedDescription }
        }
    }
}
