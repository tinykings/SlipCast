import Speech

enum DeviceSupport {
    /// Word muting needs Apple's on-device SpeechTranscriber, which isn't available on every device
    /// that runs iOS 26 (developers report iPhone 11-era hardware returns false). The App Store
    /// can't filter on this, so the app checks at launch.
    static var transcriptionAvailable: Bool {
        #if targetEnvironment(simulator)
        // SpeechTranscriber never works in the simulator; don't block UI development there.
        return true
        #else
        return SpeechTranscriber.isAvailable
        #endif
    }
}
