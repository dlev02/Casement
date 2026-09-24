import Testing
import VantageCore
@testable import VantageClientLogic

/// The Mac client's scrolling: the host posts continuous deltas negated and lines as they come,
/// so the wire values must make the posted event equal the one this Mac delivered.
@Suite struct ScrollTranslatorTests {
    typealias Input = ScrollTranslator.Input
    let began: UInt = 0x1, stationary: UInt = 0x2, changed: UInt = 0x4, ended: UInt = 0x8, cancelled: UInt = 0x10, mayBegin: UInt = 0x20

    /// What the host posts for a wire event (`InputInjector.postScroll`, naturalScroll off).
    private func posted(_ output: ScrollTranslator.Output) -> (x: Double, y: Double) {
        output.isContinuous ? (-output.deltaX, -output.deltaY) : (output.deltaX, output.deltaY)
    }

    @Test func postedEventEqualsTheLocalOne() throws {
        var translator = ScrollTranslator()
        let trackpadOutput = translator.translate(Input(deltaX: 3, deltaY: -12, isPrecise: true, phase: began))
        let trackpad = try #require(trackpadOutput)
        #expect(trackpad.isContinuous && trackpad.deltaX == -3 && trackpad.deltaY == 12)
        let postedTrackpad = posted(trackpad)
        #expect(postedTrackpad.x == 3 && postedTrackpad.y == -12)
        let wheelOutput = translator.translate(Input(deltaX: 0, deltaY: -2, isPrecise: false))
        let wheel = try #require(wheelOutput)
        #expect(!wheel.isContinuous && wheel.deltaY == -2)
        let postedWheel = posted(wheel)
        #expect(postedWheel.x == 0 && postedWheel.y == -2)
    }

    /// A trackpad scroll with its momentum, as macOS delivers it.
    @Test func phasesAndMomentumPassThrough() {
        var translator = ScrollTranslator()
        let events = [
            Input(deltaX: 0, deltaY: 0, isPrecise: true, phase: mayBegin),
            Input(deltaX: 0, deltaY: 4, isPrecise: true, phase: began),
            Input(deltaX: 0, deltaY: 9, isPrecise: true, phase: changed),
            Input(deltaX: 0, deltaY: 0, isPrecise: true, phase: stationary),
            Input(deltaX: 0, deltaY: 0, isPrecise: true, phase: ended),
            Input(deltaX: 0, deltaY: 20, isPrecise: true, momentumPhase: began),
            Input(deltaX: 0, deltaY: 11, isPrecise: true, momentumPhase: changed),
            Input(deltaX: 0, deltaY: 0, isPrecise: true, momentumPhase: ended),
        ]
        let outputs = events.compactMap { translator.translate($0) }
        #expect(outputs.map(\.phase) == [.began, .changed, .ended, .none, .none, .none])
        #expect(outputs.map(\.momentum) == [.none, .none, .none, .began, .changed, .ended])
        #expect(outputs.map(\.deltaY) == [-4, -9, -0, -20, -11, -0])
        #expect(outputs.allSatisfy { $0.isContinuous })
    }

    /// Fingers rested on the trackpad and lifted without scrolling: nothing to send.
    @Test func restedFingersSendNothing() {
        var translator = ScrollTranslator()
        #expect(translator.translate(Input(deltaX: 0, deltaY: 0, isPrecise: true, phase: mayBegin)) == nil)
        #expect(translator.translate(Input(deltaX: 0, deltaY: 0, isPrecise: true, phase: cancelled)) == nil)
        #expect(translator.translate(Input(deltaX: 0, deltaY: 3, isPrecise: true, phase: changed)) == nil)
        #expect(translator.translate(Input(deltaX: 0, deltaY: 3, isPrecise: true, momentumPhase: changed)) == nil)
    }

    /// A gesture cancelled after it began still tells the Mac.
    @Test func cancelAfterBeganIsSent() {
        var translator = ScrollTranslator()
        _ = translator.translate(Input(deltaX: 1, deltaY: 0, isPrecise: true, phase: began))
        #expect(translator.translate(Input(deltaX: 0, deltaY: 0, isPrecise: true, phase: cancelled))?.phase == .cancelled)
    }

    /// High-resolution wheels without phases scroll smoothly; an empty one is dropped.
    @Test func phaselessPreciseScrolls() {
        var translator = ScrollTranslator()
        let output = translator.translate(Input(deltaX: 0, deltaY: 2.5, isPrecise: true))
        #expect(output == ScrollTranslator.Output(deltaX: -0, deltaY: -2.5, phase: .none, momentum: .none, isContinuous: true))
        #expect(translator.translate(Input(deltaX: 0, deltaY: 0, isPrecise: true)) == nil)
    }

    /// Wheel lines go over whole, the fraction carried to the next notch; turning the wheel the
    /// other way starts from zero.
    @Test func wheelLinesCarryTheirFraction() {
        var translator = ScrollTranslator()
        let deltas = [0.4, 0.4, 0.4, 1.3, 0.1, 0.4].map { translator.translate(Input(deltaX: 0, deltaY: $0, isPrecise: false))?.deltaY }
        // 0.4, 0.8, 1.2 → 1 (0.2 left), 1.5 → 1 (0.5), 0.6, 1.0 → 1
        #expect(deltas == [nil, nil, 1, 1, nil, 1])
    }

    @Test func wheelDirectionChangeStartsOver() {
        var translator = ScrollTranslator()
        #expect(translator.translate(Input(deltaX: 0, deltaY: 0.9, isPrecise: false)) == nil)
        #expect(translator.translate(Input(deltaX: 0, deltaY: -1.2, isPrecise: false))?.deltaY == -1)
        #expect(translator.translate(Input(deltaX: -3, deltaY: 0, isPrecise: false))?.deltaX == -3)
    }
}
