import AVFoundation
import MediaToolbox
import os

/// What the audio tap should silence right now.
nonisolated struct MuteSnapshot: Sendable {
    var ranges: [ClosedRange<Double>] = []
    /// Audio at or after this time hasn't been scanned yet and is silenced as a safety net.
    /// `.infinity` once the whole episode has been scanned.
    var scannedUntil: Double = 0
}

/// Thread-safe hand-off of mute ranges from the main thread to the real-time audio thread.
/// The ranges can grow while the episode plays (e.g. while it's still being transcribed).
nonisolated final class MuteTimeline: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: MuteSnapshot())

    func update(_ snapshot: MuteSnapshot) {
        state.withLock { $0 = snapshot }
    }

    /// Never blocks: the audio thread keeps its previous copy if the lock is busy.
    func snapshotIfAvailable() -> MuteSnapshot? {
        state.withLockIfAvailable { $0 }
    }
}

/// Silences audio in real time with an MTAudioProcessingTap attached to the player item's audio mix.
nonisolated enum MuteTap {
    /// Short fade in/out around each silenced range so there are no clicks.
    static let fade = 0.015

    static func makeAudioMix(track: AVAssetTrack, timeline: MuteTimeline) -> AVAudioMix? {
        let context = MuteTapContext(timeline: timeline)
        let clientInfo = Unmanaged.passRetained(context).toOpaque()

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: clientInfo,
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<MuteTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                MuteTapContext.from(tap).prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frameCount, _, bufferList, frameCountOut, flagsOut in
                var timeRange = CMTimeRange.zero
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, frameCount, bufferList, flagsOut, &timeRange, frameCountOut)
                guard status == noErr else { return }
                MuteTapContext.from(tap).process(
                    bufferList, frames: Int(frameCountOut.pointee), start: timeRange.start)
            }
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged<MuteTapContext>.fromOpaque(clientInfo).release()
            return nil
        }

        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }
}

/// Per-tap state. Only touched on the audio thread after `prepare`, apart from the timeline.
nonisolated private final class MuteTapContext: @unchecked Sendable {
    let timeline: MuteTimeline
    private var snapshot = MuteSnapshot()
    private var sampleRate: Double = 44_100
    private var channelsPerFrame = 2
    private var isFloat32 = false
    private var isNonInterleaved = true

    init(timeline: MuteTimeline) {
        self.timeline = timeline
    }

    static func from(_ tap: MTAudioProcessingTap) -> MuteTapContext {
        Unmanaged<MuteTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    }

    func prepare(_ format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44_100
        channelsPerFrame = max(1, Int(format.mChannelsPerFrame))
        isFloat32 = format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
        isNonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    }

    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, start: CMTime) {
        if let latest = timeline.snapshotIfAvailable() { snapshot = latest }
        guard frames > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)

        // Unknown timing: fail safe (silence) unless the episode is fully scanned with nothing to mute.
        guard start.isValid, start.seconds.isFinite else {
            if !(snapshot.scannedUntil.isInfinite && snapshot.ranges.isEmpty) { silence(buffers) }
            return
        }

        let startSeconds = start.seconds
        let endSeconds = startSeconds + Double(frames) / sampleRate
        let fade = MuteTap.fade
        let ranges = snapshot.ranges
        let scannedUntil = snapshot.scannedUntil

        // First range that could affect this buffer (binary search on upper bound + fade).
        var index = firstRange(endingAfter: startSeconds - fade, in: ranges)
        let touchesRange = index < ranges.count && ranges[index].lowerBound - fade < endSeconds
        let touchesUnscanned = endSeconds > scannedUntil - fade
        guard touchesRange || touchesUnscanned else { return }  // fast path: nothing to do

        guard isFloat32 else {
            silence(buffers)  // can't scale an unexpected format; silence is the safe choice
            return
        }

        for frame in 0..<frames {
            let t = startSeconds + Double(frame) / sampleRate
            var gain: Float = 1

            if t >= scannedUntil {
                gain = 0
            } else if t > scannedUntil - fade {
                gain = Float((scannedUntil - t) / fade)
            }

            while index < ranges.count && ranges[index].upperBound + fade < t { index += 1 }
            if gain > 0, index < ranges.count {
                let range = ranges[index]
                if t >= range.lowerBound && t <= range.upperBound {
                    gain = 0
                } else if t < range.lowerBound && t > range.lowerBound - fade {
                    gain = min(gain, Float((range.lowerBound - t) / fade))
                } else if t > range.upperBound {
                    gain = min(gain, Float((t - range.upperBound) / fade))
                }
            }

            guard gain < 1 else { continue }
            if isNonInterleaved {
                for buffer in buffers {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    data[frame] *= gain
                }
            } else if let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) {
                let base = frame * channelsPerFrame
                for channel in 0..<channelsPerFrame { data[base + channel] *= gain }
            }
        }
    }

    private func firstRange(endingAfter time: Double, in ranges: [ClosedRange<Double>]) -> Int {
        var low = 0, high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].upperBound < time { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func silence(_ buffers: UnsafeMutableAudioBufferListPointer) {
        for buffer in buffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
    }
}
