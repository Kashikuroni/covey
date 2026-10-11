import XCTest
@testable import covey

final class DocumentFocusRoutingTests: XCTestCase {
    func testDocumentOwnsPlainKeysAndLocalCommands() {
        XCTAssertEqual(DocumentFocusRouting.decide(input:.init(characters:"j",documentsFocused:true)),.native)
        XCTAssertEqual(DocumentFocusRouting.decide(input:.init(characters:"k",documentsFocused:true)),.native)
        XCTAssertEqual(DocumentFocusRouting.decide(input:.init(characters:"f",command:true,documentsFocused:true)),.find)
        XCTAssertEqual(DocumentFocusRouting.decide(input:.init(characters:"w",command:true,documentsFocused:true)),.close)
        XCTAssertEqual(DocumentFocusRouting.decide(input:.init(characters:"c",command:true,documentsFocused:true)),.native)
        XCTAssertEqual(DocumentFocusRouting.decide(input:.init(characters:"l",control:true,documentsFocused:true)),.cycle(forward:true))
        XCTAssertEqual(DocumentFocusRouting.decide(input:.init(characters:"h",control:true,documentsFocused:true,textInput:true)),.cycle(forward:false))
        XCTAssertEqual(KeyRouter.route(.init(char:"j"),context:.init(mode:.normal,focus:.documents,vimMode:true,sheetOpen:false)),nil)
    }
    func testOverlaysAndOtherFocusKeepExistingRouting() {
        for blocked in [DocumentKeyInput(characters:"f",command:true,documentsFocused:true,paletteOpen:true), .init(characters:"f",command:true,documentsFocused:true,sheetOpen:true), .init(characters:"f",command:true,documentsFocused:true,reviewOpen:true)] {
            XCTAssertEqual(DocumentFocusRouting.decide(input:blocked),.pass)
        }
        XCTAssertEqual(DocumentFocusRouting.decide(input:.init(characters:"f",command:true)),.pass)
        XCTAssertEqual(commandWHandling(focus:.documents,inputMode:.normal),.perform(.closeDocumentView))
    }
    func testDocumentFramesRemainContainedAndRespectPreferredWidths() {
        for width: CGFloat in [0,4,80,320,608,1000] {
            for requested: CGFloat? in [nil,-100,100,900,.nan,.infinity] {
                let frames = PanelLayout.documentFrames(size:CGSize(width:width,height:400),requestedWidth:requested,gutter:8)
                XCTAssertGreaterThanOrEqual(frames.terminalArea.width,0)
                XCTAssertGreaterThanOrEqual(frames.documents.width,0)
                XCTAssertLessThanOrEqual(frames.documents.maxX,width)
                XCTAssertEqual(frames.terminalArea.maxX + frames.divider.width + frames.documents.width,width,accuracy:0.001)
            }
        }
        let normal = PanelLayout.documentFrames(size:CGSize(width:1008,height:400),requestedWidth:nil,gutter:8)
        XCTAssertEqual(normal.documents.width,400)
        let min = PanelLayout.documentFrames(size:CGSize(width:1008,height:400),requestedWidth:10,gutter:8)
        XCTAssertEqual(min.documents.width,320)
    }
}
