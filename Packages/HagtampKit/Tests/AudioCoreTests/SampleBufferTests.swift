import Foundation
import Testing

@testable import AudioCore

/// The visualizers' window onto the sound, with a clock the test turns.
@Suite struct SampleBufferTests {
    final class Clock: @unchecked Sendable {
        var nanoseconds: UInt64 = 0
        func advance(ms: Double) { nanoseconds += UInt64(ms * 1_000_000) }
    }

    /// Samples numbered from `start` (each sample is its position).
    func numbered(_ start: Int, _ count: Int) -> [Float] { (start..<start + count).map(Float.init) }

    @Test func theWindowMovesOnWithTheClockThroughEachBuffer() {
        let clock = Clock()
        let buffer = SampleBuffer(clock: { clock.nanoseconds })
        buffer.append(numbered(0, 4800), rate: 48000)
        // Just arrived: the window ends where the buffer starts (nothing before it yet).
        #expect(buffer.current(1024).allSatisfy { $0 == 0 })
        clock.advance(ms: 50)
        #expect(buffer.current(1024).last == 2399)
        clock.advance(ms: 16.7)
        #expect(buffer.current(1024).last == 3200)
        // Its end reached, it waits there for a late buffer.
        clock.advance(ms: 40)
        #expect(buffer.current(1024).last == 4799)
        buffer.append(numbered(4800, 4800), rate: 48000)
        #expect(buffer.current(1024).last == 4799)
        clock.advance(ms: 10)
        let window = buffer.current(1024)
        #expect(window.count == 1024 && window.last == 5279 && window.first == 4256)
        // The newest samples are still there as they were.
        #expect(buffer.latest(4).last == 9599)
    }

    @Test func bigBuffersAtHighRatesFit() {
        let clock = Clock()
        let buffer = SampleBuffer(clock: { clock.nanoseconds })
        // 100 ms at 192 kHz, twice: bigger than the ring starts.
        buffer.append(numbered(0, 19200), rate: 192_000)
        buffer.append(numbered(19200, 19200), rate: 192_000)
        clock.advance(ms: 1)
        let window = buffer.current(1024)
        #expect(window.last == Float(19200 + 191), "\(String(describing: window.last)), \(window.count)")
        #expect(zip(window, window.dropFirst()).allSatisfy { $1 - $0 == 1 })  // no wrapped-in garbage
    }

    @Test func clearingStartsOver() {
        let clock = Clock()
        let buffer = SampleBuffer(clock: { clock.nanoseconds })
        buffer.append(numbered(1, 4800), rate: 48000)
        clock.advance(ms: 200)
        #expect(buffer.current(16).last == 4800)
        buffer.clear()
        #expect(buffer.current(16).allSatisfy { $0 == 0 } && buffer.latest(16).allSatisfy { $0 == 0 })
    }
}
