import Foundation
import JavaScriptCore
import CoveyKit

enum DocumentResources {
    static var directory: URL? {
        #if SWIFT_PACKAGE
        Bundle.module.url(forResource:"Documents",withExtension:nil)
        #else
        Bundle.main.url(forResource:"Documents",withExtension:nil)
        #endif
    }
}
struct DocumentHeading: Identifiable, Equatable {
    let id: String
    let text: String
    let level: Int
}
struct DocumentPresentation {
    let source: String
    let path: String
    let context: DocumentContext
    let sourceMode: Bool
    let html: String
    let plainText: String
    let headings: [DocumentHeading]
    let error: String?
    @MainActor init(text: String, path: String, context: DocumentContext, sourceMode: Bool) {
        source = text; self.path = path; self.context = context; self.sourceMode = sourceMode
        let result = DocumentMarkdownParser.shared.parse(text,sourceMode:sourceMode)
        html = result.html; plainText = result.text; headings = result.headings; error = result.error
    }
    func matches(_ query: String) -> [NSRange] {
        guard !query.isEmpty, let regex = try? NSRegularExpression(pattern:NSRegularExpression.escapedPattern(for:query),options:.caseInsensitive) else { return [] }
        return regex.matches(in:plainText,range:NSRange(plainText.startIndex...,in:plainText)).map(\.range)
    }
}
@MainActor private final class DocumentMarkdownParser {
    static let shared = DocumentMarkdownParser()
    private let context = JSContext()!
    private var failure: String?
    private init() {
        context.exceptionHandler = { [weak self] _, exception in self?.failure = exception?.toString() }
        for file in ["markdown-it.min.js","parser.js"] {
            guard let url = DocumentResources.directory?.appendingPathComponent(file), let source = try? String(contentsOf:url,encoding:.utf8) else { failure = "Document renderer resources are missing."; return }
            context.evaluateScript(source)
            if failure != nil { return }
        }
    }
    func parse(_ text: String, sourceMode: Bool) -> (html:String,text:String,headings:[DocumentHeading],error:String?) {
        guard failure == nil, let parser = context.objectForKeyedSubscript("CoveyMarkdown"),
              let result = parser.invokeMethod("parse",withArguments:[text,sourceMode])?.toDictionary() else {
            return ("",text,[],failure ?? "Couldn’t parse this document.")
        }
        let headings = (result["headings"] as? [[String:Any]] ?? []).compactMap { value -> DocumentHeading? in
            guard let id = value["id"] as? String, let title = value["text"] as? String, let level = value["level"] as? Int else { return nil }
            return .init(id:id,text:title,level:level)
        }
        return (result["html"] as? String ?? "",result["text"] as? String ?? text,headings,failure)
    }
}
struct DocumentRenderCommand: Equatable {
    enum Action: Equatable { case revealAnchor(String), restore(DocumentPosition), find(query:String,backwards:Bool), focus }
    let id = UUID()
    let action: Action
}
enum DocumentRenderEvent {
    case position(DocumentPosition), link(String), findResult(current:Int,total:Int), ready, focused
}
