import Foundation
import CoveyKit

struct DocumentEntry: Identifiable, Equatable, Sendable {
    let path: String
    let isMarkdown: Bool
    let byteCount: Int
    var id: String { path }
}
struct DocumentCatalogSnapshot: Sendable {
    let entries: [DocumentEntry]
    let detected: Set<DocumentPresetID>
    let unreadableDirectories: [String]
}
protocol DocumentCatalogScanning: Sendable {
    func scan(context: DocumentContext, configuration: DocumentExclusionConfiguration) async throws -> DocumentCatalogSnapshot
}
struct ProjectDocumentCatalog: DocumentCatalogScanning {
    func scan(context: DocumentContext, configuration: DocumentExclusionConfiguration) async throws -> DocumentCatalogSnapshot {
        let worker = Task.detached {
            let root = URL(fileURLWithPath:context.root).resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath:root.path,isDirectory:&isDirectory), isDirectory.boolValue else { throw DocumentAccessError.unavailable }
            var detected: Set<DocumentPresetID> = [.common]
            while true {
                try Task.checkCancellation()
                let rules = try DocumentExclusionRules.compile(configuration:configuration,projectKey:context.projectKey,detected:detected)
                var found = detected, entries: [DocumentEntry] = [], unreadable: [String] = []
                var pending: [(URL, String)] = [(root, "")]
                while let (directory, relativeDirectory) = pending.popLast() {
                    try Task.checkCancellation()
                    found.formUnion(DocumentPresets.detect(directory:directory))
                    let children: [URL]
                    do { children = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]) }
                    catch {
                        if directory == root { throw DocumentAccessError.unavailable }
                        unreadable.append(relativeDirectory)
                        continue
                    }
                    for child in children {
                        try Task.checkCancellation()
                        guard let values = try? child.resourceValues(forKeys:[.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]) else { continue }
                        let path = relativeDirectory.isEmpty ? child.lastPathComponent : relativeDirectory + "/" + child.lastPathComponent
                        if values.isDirectory == true {
                            if values.isSymbolicLink != true, !rules.decision(path:path,isDirectory:true).excluded { pending.append((child,path)) }
                        } else if !rules.decision(path:path,isDirectory:false).excluded {
                            guard let safe = try? DocumentLinkResolver.fileURL(path:path,context:context),
                                  let file = try? safe.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey]), file.isRegularFile == true else { continue }
                            entries.append(.init(path:path,isMarkdown:DocumentFileLoader.isMarkdown(path),byteCount:file.fileSize ?? 0))
                        }
                    }
                }
                if found != detected { detected = found; continue }
                return DocumentCatalogSnapshot(entries:entries.sorted { $0.path < $1.path },detected:detected,unreadableDirectories:unreadable.sorted())
            }
        }
        return try await withTaskCancellationHandler(operation:{ try await worker.value },onCancel:{ worker.cancel() })
    }
}
