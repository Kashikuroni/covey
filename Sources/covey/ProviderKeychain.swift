import Foundation

/// Generic store for provider API keys in the login Keychain, under service
/// `covey.provider` — distinct from Claude Code's own `Claude Code-credentials`
/// item. Shells out to `/usr/bin/security` exactly like `Credentials.readKeychain`
/// does, so it relies on the same GUI-session assumptions (the keychain is
/// unlocked while the user is logged in). The secret never touches disk.
enum ProviderKeychain {
    static let service = "covey.provider"

    private struct CommandResult {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    /// Returns the stored key, or nil if no item exists for `account`.
    static func read(account: String) -> String? {
        guard let result = run([
            "find-generic-password", "-s", service, "-a", account, "-w",
        ]), result.status == 0 else {
            return nil
        }
        let raw = result.stdout
        return raw.isEmpty ? nil : raw
    }

    /// Stores `value` for `account`, replacing any existing item.
    static func write(account: String, value: String) -> Bool {
        // `-U` updates an existing item atomically, so a failed write cannot
        // destroy the previously stored key.
        run([
            "add-generic-password", "-s", service, "-a", account,
            "-w", value, "-U",
        ])?.status == 0
    }

    /// Removes the item for `account` if present. Idempotent.
    static func delete(account: String) -> Bool {
        guard let result = run([
            "delete-generic-password", "-s", service, "-a", account,
        ]) else { return false }
        // `security` returns errSecItemNotFound (44) when the final state is
        // already satisfied.
        return result.status == 0 || result.status == 44
    }

    private static func run(_ args: [String]) -> CommandResult? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        return CommandResult(
            stdout: String(
                decoding: out.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: String(
                decoding: err.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines),
            status: p.terminationStatus
        )
    }
}
