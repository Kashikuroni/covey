import Foundation

public enum AgentPath {
    /// Resolves the first word of `cmd` on PATH via `command -v`. The word is
    /// passed as $0, never interpolated into shell code (no injection).
    public static func resolve(_ cmd: String) -> String? {
        guard let bin = cmd.split(separator: " ").first.map(String.init), !bin.isEmpty
        else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "command -v -- \"$0\"", bin]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
