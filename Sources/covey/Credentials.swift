import Foundation

struct RawCredentials: Equatable {
    var accessToken: String
    var expiresAtMs: Int64?
    var isExpired: Bool {
        guard let expiresAtMs else { return false }
        return Double(expiresAtMs) < Date().timeIntervalSince1970 * 1000
    }
}

/// Parses `{"claudeAiOauth":{"accessToken":...,"expiresAt":<ms>}}`. An empty
/// `accessToken` is treated as absent: Claude Code >= 2.1.196 leaves a blanked
/// tombstone item behind after moving the live token, and that tombstone must
/// not masquerade as a usable credential.
func credentialsFromJSON(_ s: String) -> RawCredentials? {
    guard let data = s.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = root["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
    let expires = (oauth["expiresAt"] as? NSNumber)?.int64Value
    return RawCredentials(accessToken: token, expiresAtMs: expires)
}

/// Chooses between the two credential sources. Prefers a non-expired source;
/// keychain wins ties (Claude Code refreshes it in place). If everything is
/// expired, still returns something so the API can answer 401 rather than a
/// silent "no auth".
func pickToken(fromFile: RawCredentials?, fromKeychain: RawCredentials?) -> String? {
    switch (fromFile, fromKeychain) {
    case let (_, k?) where !k.isExpired: return k.accessToken
    case let (f?, _) where !f.isExpired: return f.accessToken
    case let (_, k?): return k.accessToken
    case let (f?, nil): return f.accessToken
    case (nil, nil): return nil
    }
}

private func readCredentialsFile() -> RawCredentials? {
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")
    guard let s = try? String(contentsOf: path, encoding: .utf8) else { return nil }
    return credentialsFromJSON(s)
}

/// Reads the `Claude Code-credentials` keychain item. `account` narrows the
/// lookup: Claude Code >= 2.1.196 stores the live token under the login user's
/// account, so a bare service query can hand back an unrelated (often blanked)
/// item. `nil` keeps the legacy service-only lookup for older layouts.
private func readKeychain(account: String?) -> RawCredentials? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    var args = ["find-generic-password", "-s", "Claude Code-credentials"]
    if let account { args += ["-a", account] }
    args.append("-w")
    p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    return credentialsFromJSON(String(decoding: data, as: UTF8.self))
}

/// OAuth access token from `~/.claude/.credentials.json` or the keychain.
func readToken() -> String? {
    let fromFile = readCredentialsFile()
    // Live token first (per-user account), legacy service-only lookup as fallback.
    let fromKeychain = readKeychain(account: NSUserName()) ?? readKeychain(account: nil)
    return pickToken(fromFile: fromFile, fromKeychain: fromKeychain)
}
