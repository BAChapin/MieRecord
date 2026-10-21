import ConversationCore
import ConversationML
import ConversationPipeline
import Foundation
import Testing

@Suite("Live transcript assembly (SPEC FR-2)")
struct LiveTranscriptAssemblerTests {
    let recording = UUID()
    let source = EngineDescriptor(identifier: "test.engine")

    @Test("volatile results replace each other and a finalized result supersedes them without duplication")
    func volatileThenFinal() {
        var assembler = LiveTranscriptAssembler(recordingID: recording, source: source)
        let range = TimeRange(start: 0, end: 2)

        #expect(assembler.apply(.volatile(text: "hel", timeRange: range)) == nil)
        #expect(assembler.transcript.volatileText == "hel")
        #expect(assembler.apply(.volatile(text: "hello wor", timeRange: range)) == nil)
        #expect(assembler.transcript.volatileText == "hello wor")

        let segment = assembler.apply(.finalized(text: " hello world ", timeRange: range, confidence: 0.9))
        #expect(segment?.text == "hello world")
        #expect(segment?.isFinal == true)
        #expect(segment?.transcriptionConfidence == 0.9)
        #expect(segment?.recordingID == recording)
        #expect(assembler.transcript.volatileText.isEmpty)
        #expect(assembler.transcript.finalizedSegments.count == 1)
        #expect(assembler.transcript.finalizedText == "hello world")
    }

    @Test("empty finalized results are dropped")
    func emptyFinal() {
        var assembler = LiveTranscriptAssembler(recordingID: recording, source: source)
        #expect(assembler.apply(.finalized(text: "   ", timeRange: nil, confidence: nil)) == nil)
        #expect(assembler.transcript.finalizedSegments.isEmpty)
    }

    @Test("flushVolatile keeps leftover provisional text, marked non-final")
    func flush() {
        var assembler = LiveTranscriptAssembler(recordingID: recording, source: source)
        assembler.apply(.volatile(text: "unfinished", timeRange: TimeRange(start: 3, end: 4)))
        let kept = assembler.flushVolatile()
        #expect(kept?.text == "unfinished")
        #expect(kept?.isFinal == false)
        #expect(kept?.timeRange == TimeRange(start: 3, end: 4))
        #expect(assembler.flushVolatile() == nil)
    }
}
