import AVFAudio
import os

/// The most recent output samples (mono), written from the audio render
/// thread and read by the visualizer.
public final class SampleBuffer: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var ring: [Float]
    private var writeIndex = 0

    public init(capacity: Int = 4096) {
        ring = [Float](repeating: 0, count: capacity)
    }

    /// Appends a buffer, mixing its channels down to mono.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength), count = Int(buffer.format.channelCount)
        guard frames > 0, count > 0 else { return }
        let scale = 1 / Float(count)
        lock.withLockUnchecked {
            let capacity = ring.count
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<count { sum += channels[channel][frame] }
                ring[writeIndex] = sum * scale
                writeIndex = (writeIndex + 1) % capacity
            }
        }
    }

    /// The last `count` samples, oldest first.
    public func latest(_ count: Int) -> [Float] {
        lock.withLockUnchecked {
            let capacity = ring.count
            let n = min(count, capacity)
            let start = (writeIndex - n + capacity) % capacity
            return (0..<n).map { ring[(start + $0) % capacity] }
        }
    }

    public func clear() {
        lock.withLockUnchecked {
            for i in ring.indices { ring[i] = 0 }
        }
    }
}
