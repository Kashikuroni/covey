import Foundation

struct RawCredentials: Equatable {
    var accessToken: String
    var expiresAtMs: Int64?
    var isExpired: Bool {
        guard let expiresAtMs else { return false }
        return Double(expiresAtMs) < Date().timeIntervalSince1970 * 1000
    }
}

/// Parses `{"claudeAiOauth":{"accessToken":...,"expiresAt":<ms>}}`.
func credentialsFromJSON(_ s: String) -> RawCredentials? {
    guard let data = s.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = root["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String else { return nil }
    let expires = (oauth["expiresAt"] as? NSNumber)?.int64Value
    return RawCredentials(accessToken: token, expiresAtMs: expires)
}

/// OAuth access token from `~/.claude/.credentials.json` or the keychain
/// (`security find-generic-password -s "Claude Code-credentials" -w`). Prefers a
/// non-expired source; when both are valid, prefers the keychain (Claude Code
/// refreshes it in place). If everything is expired, still returns something so
/// the API can answer 401 rather than a silent "no auth".
func readToken() -> String? {
    let fromFile: RawCredentials? = {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let s = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        return credentialsFromJSON(s)
    }()
    let fromKeychain: RawCredentials? = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return credentialsFromJSON(String(decoding: data, as: UTF8.self))
    }()
    // Prefer a non-expired source; keychain wins ties (refreshed in place).
    switch (fromFile, fromKeychain) {
    case let (_, k?) where !k.isExpired: return k.accessToken
    case let (f?, _) where !f.isExpired: return f.accessToken
    case let (_, k?): return k.accessToken
    case let (f?, nil): return f.accessToken
    case (nil, nil): return nil
    }
}
