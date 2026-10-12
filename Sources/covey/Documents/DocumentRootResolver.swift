import Foundation
import CoveyKit
import CoveyGit

struct DocumentRootResolution: Sendable { let context: DocumentContext; let usedDirectoryFallback: Bool }
enum DocumentRootResolver {
    static func resolve(session: Session) async -> DocumentRootResolution {
        await resolve(directory: session.dir, sessionName: session.name, worktreeRepo: session.worktreeRepo)
    }
    static func resolve(directory: String, sessionName: String, worktreeRepo: String?) async -> DocumentRootResolution {
        await Task.detached {
            func canonical(_ path: String) -> String { URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath().path }
            let top = try? GitRunner.run(in:directory,["rev-parse","--show-toplevel"],readOnly:true,timeout:3)
            let root = canonical(top ?? directory)
            var key = root
            if let repo = worktreeRepo, !repo.isEmpty { key = canonical(repo) }
            else if top != nil,
                    let listing = try? GitRunner.run(in:root,["worktree","list","--porcelain","-z"],readOnly:true,timeout:3),
                    let first = listing.split(separator:"\0").first, first.hasPrefix("worktree ") {
                key = canonical(String(first.dropFirst(9)))
            }
            return DocumentRootResolution(context:.init(sourceSession:sessionName,root:root,projectKey:key),usedDirectoryFallback:top == nil)
        }.value
    }
}
