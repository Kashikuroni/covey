import Foundation
import Darwin
import CoveyKit

enum DocumentFileSnapshot: Equatable, Sendable {
    case text(path:String,text:String,isMarkdown:Bool,byteCount:Int)
    case binary(path:String,byteCount:Int)
    case tooLarge(path:String,byteCount:Int)
}
protocol DocumentFileLoading: Sendable {
    func load(path:String,context:DocumentContext) async throws -> DocumentFileSnapshot
}
struct DocumentFileLoader: DocumentFileLoading {
    static let maxPreviewBytes = 4 * 1024 * 1024
    static func isMarkdown(_ path: String) -> Bool { ["md","markdown"].contains((path as NSString).pathExtension.lowercased()) }
    func load(path: String, context: DocumentContext) async throws -> DocumentFileSnapshot {
        try await Task.detached {
            let url = try DocumentLinkResolver.fileURL(path:path,context:context)
            let fd = Darwin.open(url.path,O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
            guard fd >= 0 else { throw DocumentAccessError.unavailable }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw DocumentAccessError.notRegularFile }
            let size = Int(info.st_size)
            if size > Self.maxPreviewBytes { return .tooLarge(path:path,byteCount:size) }
            var bytes = Data(), buffer = [UInt8](repeating:0,count:64 * 1024)
            while bytes.count <= Self.maxPreviewBytes {
                try Task.checkCancellation()
                let wanted = min(buffer.count,Self.maxPreviewBytes + 1 - bytes.count)
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd,$0.baseAddress,wanted) }
                if count < 0 { if errno == EINTR { continue }; throw DocumentAccessError.unavailable }
                if count == 0 { break }
                bytes.append(contentsOf:buffer.prefix(count))
            }
            if bytes.count > Self.maxPreviewBytes { return .tooLarge(path:path,byteCount:bytes.count) }
            guard !bytes.contains(0), let text = String(data:bytes,encoding:.utf8) else { return .binary(path:path,byteCount:bytes.count) }
            return .text(path:path,text:text,isMarkdown:Self.isMarkdown(path),byteCount:bytes.count)
        }.value
    }
}
