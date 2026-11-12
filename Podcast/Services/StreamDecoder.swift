import AVFoundation
import AudioToolbox

/// Decodes compressed audio bytes (MP3, AAC, or M4A with its index at the front) into PCM in the
/// speech analyzer's format, as the bytes are fed in. Not thread-safe: use from one queue.
nonisolated final class StreamDecoder {
    private(set) var failed = false
    /// True once at least one audio packet has been decoded.
    private(set) var producedAudio = false

    private let targetFormat: AVAudioFormat
    private let output: (AVAudioPCMBuffer) -> Void
    private var streamID: AudioFileStreamID?
    private var sourceFormat: AVAudioFormat?
    private var pcmFormat: AVAudioFormat?
    private var decoder: AVAudioConverter?
    private var resampler: AVAudioConverter?
    private var maxPacketSize = 0

    init(targetFormat: AVAudioFormat, output: @escaping (AVAudioPCMBuffer) -> Void) {
        self.targetFormat = targetFormat
        self.output = output
    }

    deinit {
        if let streamID { AudioFileStreamClose(streamID) }
    }

    /// - Parameter typeHint: e.g. `kAudioFileMP3Type`; 0 lets the parser guess.
    func open(typeHint: AudioFileTypeID) -> Bool {
        let clientData = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioFileStreamOpen(
            clientData,
            { clientData, streamID, propertyID, _ in
                Unmanaged<StreamDecoder>.fromOpaque(clientData).takeUnretainedValue()
                    .propertyChanged(streamID, propertyID)
            },
            { clientData, byteCount, packetCount, data, descriptions in
                Unmanaged<StreamDecoder>.fromOpaque(clientData).takeUnretainedValue()
                    .received(byteCount: byteCount, packetCount: packetCount, data: data, descriptions: descriptions)
            },
            typeHint,
            &streamID
        )
        return status == noErr
    }

    func feed(_ data: Data) {
        guard let streamID, !failed, !data.isEmpty else { return }
        let status = data.withUnsafeBytes { raw in
            AudioFileStreamParseBytes(streamID, UInt32(raw.count), raw.baseAddress, [])
        }
        if status != noErr { failed = true }
    }

    static func typeHint(mimeType: String?, pathExtension: String) -> AudioFileTypeID {
        switch mimeType?.lowercased() {
        case "audio/mpeg", "audio/mp3": return kAudioFileMP3Type
        case "audio/aac", "audio/aacp": return kAudioFileAAC_ADTSType
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return kAudioFileM4AType
        default: break
        }
        switch pathExtension.lowercased() {
        case "mp3": return kAudioFileMP3Type
        case "aac": return kAudioFileAAC_ADTSType
        case "m4a", "mp4": return kAudioFileM4AType
        default: return 0
        }
    }

    // MARK: - AudioFileStream callbacks

    private func propertyChanged(_ streamID: AudioFileStreamID, _ propertyID: AudioFileStreamPropertyID) {
        guard propertyID == kAudioFileStreamProperty_ReadyToProducePackets, decoder == nil else { return }

        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileStreamGetProperty(streamID, kAudioFileStreamProperty_DataFormat, &size, &description) == noErr,
              description.mFormatID != kAudioFormatLinearPCM,  // only compressed formats are streamed
              let source = AVAudioFormat(streamDescription: &description),
              let pcm = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: description.mSampleRate,
                  channels: max(1, description.mChannelsPerFrame),
                  interleaved: false),
              let decoder = AVAudioConverter(from: source, to: pcm),
              let resampler = AVAudioConverter(from: pcm, to: targetFormat)
        else {
            failed = true
            return
        }

        var cookieSize: UInt32 = 0
        if AudioFileStreamGetPropertyInfo(streamID, kAudioFileStreamProperty_MagicCookieData, &cookieSize, nil) == noErr,
           cookieSize > 0 {
            var cookie = Data(count: Int(cookieSize))
            let status = cookie.withUnsafeMutableBytes { raw in
                AudioFileStreamGetProperty(streamID, kAudioFileStreamProperty_MagicCookieData, &cookieSize, raw.baseAddress!)
            }
            if status == noErr { decoder.magicCookie = cookie }
        }

        var upperBound: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioFileStreamGetProperty(streamID, kAudioFileStreamProperty_PacketSizeUpperBound, &size, &upperBound) == noErr {
            maxPacketSize = Int(upperBound)
        }

        sourceFormat = source
        pcmFormat = pcm
        self.decoder = decoder
        self.resampler = resampler
    }

    private func received(
        byteCount: UInt32,
        packetCount: UInt32,
        data: UnsafeRawPointer,
        descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        guard !failed, let sourceFormat, let pcmFormat, let decoder, packetCount > 0, let descriptions else { return }

        let packets = UnsafeBufferPointer(start: descriptions, count: Int(packetCount))
        let largestPacket = packets.map { Int($0.mDataByteSize) }.max() ?? 0
        let compressed = AVAudioCompressedBuffer(
            format: sourceFormat,
            packetCapacity: packetCount,
            maximumPacketSize: max(maxPacketSize, largestPacket, 1)
        )
        compressed.data.copyMemory(from: data, byteCount: Int(byteCount))
        compressed.byteLength = byteCount
        compressed.packetCount = packetCount
        compressed.packetDescriptions?.update(from: descriptions, count: Int(packetCount))

        let framesPerPacket = Int(sourceFormat.streamDescription.pointee.mFramesPerPacket)
        let capacity = AVAudioFrameCount(Int(packetCount) * (framesPerPacket > 0 ? framesPerPacket : 1152))
        convert(using: decoder, input: compressed, outputFormat: pcmFormat, capacity: capacity) { pcm in
            self.resample(pcm)
        }
    }

    private func resample(_ pcm: AVAudioPCMBuffer) {
        guard let resampler else { return }
        let ratio = targetFormat.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 512
        convert(using: resampler, input: pcm, outputFormat: targetFormat, capacity: capacity) { converted in
            producedAudio = true
            output(converted)
        }
    }

    /// Runs one input buffer through a converter, emitting output buffers. Returns `.noDataNow`
    /// after the input so the converter keeps its state for the next call (no gaps between chunks).
    private func convert(
        using converter: AVAudioConverter,
        input: AVAudioBuffer,
        outputFormat: AVAudioFormat,
        capacity: AVAudioFrameCount,
        emit: (AVAudioPCMBuffer) -> Void
    ) {
        let supplied = InputFlag()
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: max(capacity, 1)) else { return }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if supplied.value {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied.value = true
                inputStatus.pointee = .haveData
                return input
            }
            if out.frameLength > 0 { emit(out) }
            if status == .error {
                failed = true
                return
            }
            if status != .haveData || out.frameLength == 0 { return }
        }
    }
}

nonisolated private final class InputFlag: @unchecked Sendable {
    var value = false
}
