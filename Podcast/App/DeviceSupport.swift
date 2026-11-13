import Speech

enum DeviceSupport {
    /// Filtering requires Apple Speech support. Unfiltered playback is available without it.
    static var transcriptionAvailable: Bool {
        #if targetEnvironment(simulator)
        // SpeechTranscriber never works in the simulator; don't block UI development there.
        return true
        #else
        return SpeechTranscriber.isAvailable
        #endif
    }
}
