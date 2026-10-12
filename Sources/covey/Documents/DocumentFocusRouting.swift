import Foundation

struct DocumentKeyInput {
    var characters: String
    var command = false
    var control = false
    var shift = false
    var option = false
    var documentsFocused = false
    var textInput = false
    var paletteOpen = false
    var sheetOpen = false
    var reviewOpen = false
    var overlayOpen = false
}
enum DocumentKeyDecision: Equatable { case pass, native, find, close, cycle(forward:Bool) }
enum DocumentFocusRouting {
    static func decide(input: DocumentKeyInput) -> DocumentKeyDecision {
        guard input.documentsFocused, !input.paletteOpen, !input.sheetOpen, !input.reviewOpen, !input.overlayOpen else { return .pass }
        let character = input.characters.first.map(latinize)
        if input.command, !input.control, !input.shift, !input.option {
            if character == "f" { return .find }
            if character == "w" { return .close }
        }
        if input.control, !input.command, !input.shift, !input.option {
            if character == "h" { return .cycle(forward:false) }
            if character == "l" { return .cycle(forward:true) }
        }
        return .native
    }
}
