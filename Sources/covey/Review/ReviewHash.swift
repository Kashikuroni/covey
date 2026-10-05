import Foundation
import CryptoKit
import CoveyGit

enum ReviewHash {
    /// sha256 of the diff's lines (kind + text, no line numbers — an edit
    /// elsewhere in the file that only shifts numbers is not a change). Files
    /// whose content git does not show (binary, untracked over the size cap)
    /// hash their mtime/size instead.
    static func of(_ diff: FileDiff, file: ChangedFile, stamp: FileStamp?) -> String {
        var hasher = SHA256()
        for hunk in diff.hunks {
            for line in hunk.lines {
                let tag: String
                switch line.kind {
                case .added: tag = "+"
                case .removed: tag = "-"
                case .context: tag = " "
                }
                hasher.update(data: Data((tag + line.text + "\n").utf8))
            }
        }
        if diff.isBinary || file.isBinary || (file.isUntracked && file.added == nil) {
            hasher.update(data: Data("stamp:\(stamp?.mtime ?? 0):\(stamp?.size ?? 0)".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
