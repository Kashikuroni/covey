import Foundation

/// Recognized git refusals get tailored advice; everything else keeps git's
/// own message (phase-1 spec's deferred error-mapping).
func refusalAdvice(_ message: String) -> String? {
    if message.contains("index.lock") {
        return "Another git operation is in progress — wait for the agent's git to finish, then retry"
    }
    if message.contains("non-fast-forward") {
        return "The remote moved ahead — pull with rebase in the worktree, then push again"
    }
    return nil
}

/// The text a refusal surface shows: the advice when recognized, git's
/// message otherwise.
func refusalText(_ error: Error) -> String {
    let message = String(describing: error)
    return refusalAdvice(message) ?? message
}
