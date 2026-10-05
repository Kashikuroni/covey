import Foundation

struct ShellError: Error, CustomStringConvertible {
    let description: String
}

/// A throwaway repository on disk: `main` with one empty commit.
final class TestRepo {
    let path: String

    init() throws {
        path = "\(NSTemporaryDirectory())covey-git-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try sh("git -C '\(path)' init -q -b main")
        try commitAll("init", allowEmpty: true)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }

    func sh(_ cmd: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ShellError(description: "sh failed: \(cmd)") }
    }

    /// Writes `content` at `rel` (creating directories), relative to the repo.
    func write(_ rel: String, _ content: String) throws {
        let full = (path as NSString).appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try content.write(toFile: full, atomically: true, encoding: .utf8)
    }

    func commitAll(_ message: String, allowEmpty: Bool = false) throws {
        let empty = allowEmpty ? "--allow-empty" : ""
        try sh("git -C '\(path)' add -A && git -C '\(path)' -c user.email=t@t -c user.name=t commit -q \(empty) -m '\(message)'")
    }
}
