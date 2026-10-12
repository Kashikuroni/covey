import Foundation
import CoveyKit
import Darwin

enum DocumentAccessError: LocalizedError {
    case outsideProject, unsupportedLink, notRegularFile, unavailable
    var errorDescription: String? {
        switch self {
        case .outsideProject: return "This path is outside the document's project."
        case .unsupportedLink: return "This link type is not supported."
        case .notRegularFile: return "This path is not a regular file."
        case .unavailable: return "The file or project is unavailable."
        }
    }
}
enum DocumentLinkTarget: Equatable { case local(path:String,fragment:String?), web(URL) }
enum DocumentLinkResolver {
    /// Resolve internal symlinks first, then open from the project descriptor.
    /// Refusing symlinks during the descriptor walk prevents a directory swap
    /// between validation and reading from escaping the project.
    static func openRegularFile(path: String, context: DocumentContext) throws -> Int32 {
        let url = try fileURL(path:path,context:context)
        let relative = try relativePath(url:url,context:context)
        let parts = relative.split(separator:"/").map(String.init)
        var directory = Darwin.open(context.root,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw DocumentAccessError.unavailable }
        defer { Darwin.close(directory) }
        for part in parts.dropLast() {
            let next = Darwin.openat(directory,part,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw DocumentAccessError.unavailable }
            Darwin.close(directory); directory = next
        }
        guard let name = parts.last else { throw DocumentAccessError.notRegularFile }
        let fd = Darwin.openat(directory,name,O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DocumentAccessError.unavailable }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG else { Darwin.close(fd); throw DocumentAccessError.notRegularFile }
        return fd
    }
    private static func canonicalURL(_ url: URL) -> URL {
        let normalized = url.standardizedFileURL
        if FileManager.default.fileExists(atPath: normalized.path) {
            return normalized.resolvingSymlinksInPath()
        }
        let parent = normalized.deletingLastPathComponent()
        guard parent.path != normalized.path else { return normalized }
        return canonicalURL(parent).appendingPathComponent(normalized.lastPathComponent)
    }
    static func fileURL(path: String, context: DocumentContext) throws -> URL {
        let root = URL(fileURLWithPath:context.root).standardizedFileURL.resolvingSymlinksInPath()
        let url = canonicalURL(path.hasPrefix("/") ? URL(fileURLWithPath:path) : root.appendingPathComponent(path))
        let base = root.pathComponents, parts = url.pathComponents
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { throw DocumentAccessError.outsideProject }
        return url
    }
    static func relativePath(url: URL, context: DocumentContext) throws -> String {
        let safe = try fileURL(path:url.path,context:context)
        let root = URL(fileURLWithPath:context.root).resolvingSymlinksInPath()
        return safe.pathComponents.dropFirst(root.pathComponents.count).joined(separator:"/")
    }
    static func resolve(_ reference: String, from path: String, context: DocumentContext) throws -> DocumentLinkTarget {
        if let components = URLComponents(string:reference), let scheme = components.scheme {
            guard ["http","https"].contains(scheme.lowercased()), let url = components.url else { throw DocumentAccessError.unsupportedLink }
            return .web(url)
        }
        let pieces = reference.split(separator:"#",maxSplits:1,omittingEmptySubsequences:false)
        let raw = String(pieces[0]), decoded = raw.removingPercentEncoding ?? raw
        let fragment = pieces.count == 2 ? String(pieces[1]).removingPercentEncoding ?? String(pieces[1]) : nil
        let dir = (path as NSString).deletingLastPathComponent
        let target = decoded.isEmpty ? path : decoded.hasPrefix("/") ? decoded : (dir as NSString).appendingPathComponent(decoded)
        let url = try fileURL(path:target,context:context)
        return .local(path:try relativePath(url:url,context:context),fragment:fragment)
    }
}
