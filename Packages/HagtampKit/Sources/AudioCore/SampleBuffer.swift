import AVFAudio
import Foundation
import os

/// The most recent output samples (mono), written from the audio graph's
/// tap and read by the visualizers.
///
/// The tap hands over about 100 ms at a time (macOS picks the size,
/// whatever is asked for), so the newest samples change only ten times a
/// second. `current` reads a window that moves on with the clock instead:
/// it plays each buffer through over the time until the next one, a buffer
/// behind the newest.
public final class SampleBuffer: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var ring: [Float]
    /// Samples written since the start; the ring position is this modulo its size.
    private var written = 0
    /// The tap's latest buffer: where it ends, its length, its sample rate and when it came.
    private var chunk: (end: Int, length: Int, rate: Double, arrival: UInt64)?
    /// Monotonic nanoseconds.
    private let clock: @Sendable () -> UInt64

    public init(capacity: Int = 16384, clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        ring = [Float](repeating: 0, count: capacity)
        self.clock = clock
    }

    /// Appends a buffer, mixing its channels down to mono.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength), count = Int(buffer.format.channelCount)
        guard frames > 0, count > 0 else { return }
        let scale = 1 / Float(count)
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<count {
            let samples = channels[channel]
            for frame in 0..<frames { mono[frame] += samples[frame] }
        }
        for frame in 0..<frames { mono[frame] *= scale }
        append(mono, rate: buffer.format.sampleRate)
    }

    /// Appends mono samples that arrived now.
    func append(_ samples: [Float], rate: Double) {
        let arrival = clock()
        lock.withLockUnchecked {
            // Room for a whole buffer behind the window, at any sample rate.
            let needed = samples.count * 2 + 4096
            if ring.count < needed { grow(to: needed) }
            let capacity = ring.count
            for sample in samples {
                ring[written % capacity] = sample
                written += 1
            }
            chunk = (written, samples.count, rate, arrival)
        }
    }

    private func grow(to size: Int) {
        var capacity = ring.count
        while capacity < size { capacity *= 2 }
        var bigger = [Float](repeating: 0, count: capacity)
        for position in max(0, written - ring.count)..<written { bigger[position % capacity] = ring[position % ring.count] }
        ring = bigger
    }

    /// The last `count` samples, oldest first.
    public func latest(_ count: Int) -> [Float] {
        lock.withLockUnchecked { window(endingAt: written, count) }
    }

    /// `count` samples, oldest first, ending where the sound has got to by
    /// now: the tap's latest buffer, from its start when it came to its end
    /// a buffer's duration later (and there it waits if the next is late).
    public func current(_ count: Int) -> [Float] {
        let now = clock()
        return lock.withLockUnchecked {
            guard let chunk else { return window(endingAt: written, count) }
            let start = chunk.end - chunk.length
            let played = now < chunk.arrival ? 0 : Int(Double(now - chunk.arrival) * chunk.rate / 1e9)
            let end = min(chunk.end, start + played)
            return window(endingAt: end, count)
        }
    }

    /// Needs the lock.
    private func window(endingAt end: Int, _ count: Int) -> [Float] {
        let capacity = ring.count
        let n = min(count, capacity)
        return (0..<n).map { i in
            let position = end - n + i
            return position < 0 || position < written - capacity ? 0 : ring[position % capacity]
        }
    }

    public func clear() {
        lock.withLockUnchecked {
            for i in ring.indices { ring[i] = 0 }
            chunk = nil
        }
    }
}
