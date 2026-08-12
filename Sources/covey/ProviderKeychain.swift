import Foundation

/// Generic store for provider API keys in the login Keychain, under service
/// `covey.provider` — distinct from Claude Code's own `Claude Code-credentials`
/// item. Shells out to `/usr/bin/security` exactly like `Credentials.readKeychain`
/// does, so it relies on the same GUI-session assumptions (the keychain is
/// unlocked while the user is logged in). The secret never touches disk.
enum ProviderKeychain {
    static let service = "covey.provider"

    /// Returns the stored key, or nil if no item exists for `account`.
    static func read(account: String) -> String? {
        guard let raw = run(["find-generic-password", "-s", service, "-a", account, "-w"]) else {
            return nil
        }
        return raw.isEmpty ? nil : raw
    }

    /// Stores `value` for `account`, replacing any existing item.
    static func write(account: String, value: String) {
        // add-generic-password fails if the item already exists; delete first.
        _ = run(["delete-generic-password", "-s", service, "-a", account])
        _ = run(["add-generic-password", "-s", service, "-a", account, "-w", value, "-U"])
    }

    /// Removes the item for `account` if present. Idempotent.
    static func delete(account: String) {
        _ = run(["delete-generic-password", "-s", service, "-a", account])
    }

    @discardableResult
    private static func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
