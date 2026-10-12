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
    var excludedPaths: [DocumentExcludedPath] = []
    var excludedPathCount = 0
}
struct DocumentExcludedPath: Identifiable, Sendable {
    let path: String
    let isDirectory: Bool
    let decision: DocumentExclusionDecision
    var id: String { path }
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
                var excluded: [DocumentExcludedPath] = [], excludedCount = 0
                var pending: [(URL, String)] = [(root, "")]
                var restart = false
                while let (directory, relativeDirectory) = pending.popLast() {
                    try Task.checkCancellation()
                    found.formUnion(DocumentPresets.detect(directory:directory,context:context))
                    if found != detected {
                        // Apply newly discovered policy before descending into
                        // dependencies or caches in this same directory.
                        detected = found; restart = true; break
                    }
                    let children: [URL]
                    do { children = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]) }
                    catch {
                        if directory == root { throw DocumentAccessError.unavailable }
                        unreadable.append(relativeDirectory)
                        continue
                    }
                    for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                        try Task.checkCancellation()
                        guard let values = try? child.resourceValues(forKeys:[.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]) else { continue }
                        let path = relativeDirectory.isEmpty ? child.lastPathComponent : relativeDirectory + "/" + child.lastPathComponent
                        let decision = rules.decision(path:path,isDirectory:values.isDirectory == true)
                        if decision.excluded {
                            excludedCount += 1
                            if excluded.count < 200 { excluded.append(.init(path:path,isDirectory:values.isDirectory == true,decision:decision)) }
                            continue
                        }
                        if values.isDirectory == true {
                            if values.isSymbolicLink != true, !rules.decision(path:path,isDirectory:true).excluded { pending.append((child,path)) }
                        } else if !rules.decision(path:path,isDirectory:false).excluded {
                            guard let safe = try? DocumentLinkResolver.fileURL(path:path,context:context),
                                  let file = try? safe.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey]), file.isRegularFile == true else { continue }
                            entries.append(.init(path:path,isMarkdown:DocumentFileLoader.isMarkdown(path),byteCount:file.fileSize ?? 0))
                        }
                    }
                }
                if restart { continue }
                return DocumentCatalogSnapshot(entries:entries.sorted { $0.path < $1.path },detected:detected,unreadableDirectories:unreadable.sorted(),excludedPaths:excluded.sorted { $0.path < $1.path },excludedPathCount:excludedCount)
            }
        }
        return try await withTaskCancellationHandler(operation:{ try await worker.value },onCancel:{ worker.cancel() })
    }
}
