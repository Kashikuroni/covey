import Foundation

extension ReviewModel {
    func perform(_ action: ReviewKeyAction) async {
        switch action {
        case .nextFile: await nextFile(1)
        case .previousFile: await nextFile(-1)
        case .nextHunk: jumpStop(1)
        case .previousHunk: jumpStop(-1)
        case .nextIssue: await nextIssue(1)
        case .previousIssue: await nextIssue(-1)
        case .nextUnreviewed: await nextUnreviewed()
        case .toggleReviewed: await toggleReviewed()
        case .toggleFullFile:
            guard selectedPath != nil else { return }
            diffOpen = true
            await toggleFullFile()
        case .comment: composeAtCurrentStop()
        case .fit: fitCanvas()
        case .zoomReset: resetZoom()
        case .zoomIn: zoomCanvas(by: 1.2)
        case .zoomOut: zoomCanvas(by: 1 / 1.2)
        case .focusTree:
            sidebarVisible = true
            sidebarTab = .files
        case .focusDiff:
            if selectedPath != nil { diffOpen = true }
        case .focusCard: focusCard()
        case .showKeys: keysOverlayOpen = true
        case .escape: await escape()
        case .closeWindow: break   // the window closes itself
        }
    }
}
