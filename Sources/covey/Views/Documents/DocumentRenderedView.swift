import SwiftUI
import WebKit
import UniformTypeIdentifiers
import Darwin
import CoveyKit

struct DocumentRenderedView: NSViewRepresentable {
    let presentation: DocumentPresentation
    let command: DocumentRenderCommand?
    var position: DocumentPosition? = nil
    var fragment: String? = nil
    var theme: Theme = .dark
    let onEvent: (DocumentRenderEvent) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(context.coordinator.assets,forURLScheme:"covey-document")
        configuration.userContentController.add(context.coordinator,name:"document")
        let view = WKWebView(frame:.zero,configuration:configuration)
        view.navigationDelegate = context.coordinator
        context.coordinator.view = view
        view.setValue(false,forKey:"drawsBackground")
        view.loadHTMLString("""
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src covey-document:; style-src covey-document:; img-src covey-document:; connect-src 'none'; form-action 'none'; base-uri 'none'"><link rel="stylesheet" href="covey-document://bundle/reader.css"></head><body><main id="document" tabindex="0" aria-label="Read-only project document"></main><script src="covey-document://bundle/prism.js"></script><script src="covey-document://bundle/reader.js"></script></body></html>
        """,baseURL:nil)
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onEvent = onEvent
        coordinator.assets.context = presentation.context
        coordinator.assets.documentPath = presentation.path
        let changed = coordinator.source != presentation.source || coordinator.path != presentation.path || coordinator.sourceMode != presentation.sourceMode
        if changed {
            coordinator.source = presentation.source; coordinator.path = presentation.path; coordinator.sourceMode = presentation.sourceMode
            var value: [String:Any] = ["html":presentation.html,"theme":theme.rawValue]
            if let position { value["position"] = Self.positionValue(position) }
            if let fragment { value["fragment"] = fragment }
            coordinator.pendingPresentation = value
        }
        if coordinator.theme != theme.rawValue { coordinator.theme = theme.rawValue; coordinator.pendingTheme = theme.rawValue }
        if let command, coordinator.commandID != command.id {
            coordinator.commandID = command.id
            coordinator.pendingCommand = command
        }
        coordinator.flush()
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName:"document")
        coordinator.assets.stopAll(); coordinator.onEvent = nil
    }
    private static func positionValue(_ position: DocumentPosition) -> [String:Any] {
        var value: [String:Any] = ["offset":position.offset,"progress":position.progress]
        if let id = position.anchorID { value["anchorID"] = id }
        return value
    }
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var view: WKWebView?
        fileprivate let assets = DocumentAssetHandler()
        var onEvent: ((DocumentRenderEvent) -> Void)?
        var ready = false
        var source: String?, path: String?, sourceMode: Bool?, theme: String?
        var commandID: UUID?
        var pendingPresentation: [String:Any]?
        var pendingTheme: String?
        var pendingCommand: DocumentRenderCommand?
        func flush() {
            guard ready, let view else { return }
            if let value = pendingPresentation {
                pendingPresentation = nil
                view.callAsyncJavaScript("window.CoveyDocument.render(value)",arguments:["value":value],in:nil,in:.page,completionHandler:nil)
            }
            if let value = pendingTheme {
                pendingTheme = nil
                view.callAsyncJavaScript("window.CoveyDocument.theme(value)",arguments:["value":value],in:nil,in:.page,completionHandler:nil)
            }
            if let command = pendingCommand {
                pendingCommand = nil
                let value: [String:Any]
                switch command.action {
                case .revealAnchor(let id): value = ["type":"anchor","id":id]
                case .restore(let position): value = ["type":"restore","position":DocumentRenderedView.positionValue(position)]
                case .find(let query,let backwards): value = ["type":"find","query":query,"backwards":backwards]
                case .focus:
                    view.window?.makeFirstResponder(view)
                    value = ["type":"focus"]
                }
                view.callAsyncJavaScript("window.CoveyDocument.command(value)",arguments:["value":value],in:nil,in:.page,completionHandler:nil)
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let value = message.body as? [String:Any], let type = value["type"] as? String else { return }
            switch type {
            case "ready": ready = true; flush(); onEvent?(.ready)
            case "focused": onEvent?(.focused)
            case "link": if let reference = value["reference"] as? String { onEvent?(.link(reference)) }
            case "position":
                guard let position = value["value"] as? [String:Any], let offset = position["offset"] as? Double, let progress = position["progress"] as? Double,
                      offset.isFinite, progress.isFinite else { return }
                onEvent?(.position(.init(anchorID:position["anchorID"] as? String,offset:offset,progress:min(1,max(0,progress)))))
            case "find": if let current = value["current"] as? Int, let total = value["total"] as? Int { onEvent?(.findResult(current:current,total:total)) }
            default: break
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .other, action.request.url?.absoluteString == "about:blank" { decisionHandler(.allow) }
            else { decisionHandler(.cancel) }
        }
    }
}

/// Only bundled renderer code and validated project images can be served.
@MainActor private final class DocumentAssetHandler: NSObject, WKURLSchemeHandler {
    var context: DocumentContext?
    var documentPath = ""
    private var tasks: [ObjectIdentifier: Task<Void,Never>] = [:]
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        let capturedContext = context, path = documentPath
        tasks[key] = Task { [weak self] in
            do {
                guard let url = urlSchemeTask.request.url else { throw DocumentAccessError.unavailable }
                let data: Data, mime: String
                if url.host == "bundle", ["reader.css","reader.js","prism.js"].contains(url.lastPathComponent),
                   let resource = DocumentResources.directory?.appendingPathComponent(url.lastPathComponent) {
                    data = try Data(contentsOf:resource)
                    mime = url.pathExtension == "css" ? "text/css" : "application/javascript"
                } else if url.host == "image", let capturedContext,
                          let reference = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first(where: { $0.name == "ref" })?.value,
                          case .local(let relative,_) = try DocumentLinkResolver.resolve(reference,from:path,context:capturedContext) {
                    let image = try DocumentLinkResolver.fileURL(path:relative,context:capturedContext)
                    let type = UTType(filenameExtension:image.pathExtension)
                    guard type?.conforms(to:.image) == true else { throw DocumentAccessError.unsupportedLink }
                    mime = type?.preferredMIMEType ?? "application/octet-stream"
                    data = try await Task.detached {
                        let fd = try DocumentLinkResolver.openRegularFile(path:relative,context:capturedContext)
                        defer { Darwin.close(fd) }
                        var info = stat()
                        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= DocumentFileLoader.maxPreviewBytes else { throw DocumentAccessError.notRegularFile }
                        var bytes = Data(), buffer = [UInt8](repeating:0,count:65536)
                        while bytes.count <= DocumentFileLoader.maxPreviewBytes {
                            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd,$0.baseAddress,min($0.count,DocumentFileLoader.maxPreviewBytes+1-bytes.count)) }
                            if count < 0 { if errno == EINTR { continue }; throw DocumentAccessError.unavailable }
                            if count == 0 { break }
                            bytes.append(contentsOf:buffer.prefix(count))
                        }
                        guard bytes.count <= DocumentFileLoader.maxPreviewBytes else { throw DocumentAccessError.unavailable }
                        return bytes
                    }.value
                } else { throw DocumentAccessError.unsupportedLink }
                guard !Task.isCancelled, let self, self.tasks[key] != nil else { return }
                urlSchemeTask.didReceive(URLResponse(url:url,mimeType:mime,expectedContentLength:data.count,textEncodingName:nil))
                urlSchemeTask.didReceive(data); urlSchemeTask.didFinish(); self.tasks[key] = nil
            } catch {
                guard !Task.isCancelled, let self, self.tasks[key] != nil else { return }
                urlSchemeTask.didFailWithError(error); self.tasks[key] = nil
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) { tasks.removeValue(forKey:ObjectIdentifier(urlSchemeTask))?.cancel() }
    func stopAll() { for task in tasks.values { task.cancel() }; tasks.removeAll() }
}
