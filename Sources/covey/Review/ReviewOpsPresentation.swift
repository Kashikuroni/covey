import CoveyGit

/// Pure title logic for the Ops buttons (busy wording mirrors the send button).
func pushButtonTitle(upstream: UpstreamInfo?, branch: String, pushing: Bool,
                     upstreamPending: Bool) -> String {
    if pushing { return "Pushing…" }
    if upstreamPending { return "Publish · origin/\(branch)" }
    guard let upstream else { return "Push" }
    return upstream.ahead > 0 ? "Push ↑\(upstream.ahead)" : "Push"
}

func commitButtonTitle(committing: Bool) -> String {
    committing ? "Committing…" : "Commit"
}
