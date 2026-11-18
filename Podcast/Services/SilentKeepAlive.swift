import AVFoundation

/// Plays silence so iOS keeps the app running, and still allows it to start audio, while an
/// episode waits for filtering with the screen locked. A suspended app can't do either.
final class SilentKeepAlive {
    private var engine: AVAudioEngine?
    private var wanted = false
    /// When the session activation in flight began. One that hasn't returned after a few
    /// seconds is treated as stuck, so a later `start()` can try again.
    private var activationStarted: Date?
    private var isActivating: Bool {
        activationStarted.map { Date().timeIntervalSince($0) < 3 } ?? false
    }

    /// True while the silence engine is running and holding the audio session open.
    var isRunning: Bool { engine?.isRunning == true }

    func start() {
        wanted = true
        if let engine {
            if !engine.isRunning { try? engine.start() }  // e.g. after a phone call interruption
            return
        }
        guard !isActivating else { return }
        let started = Date()
        activationStarted = started
        Task {
            await Self.activateSession()
            guard activationStarted == started else { return }  // a newer attempt took over
            activationStarted = nil
            guard wanted, engine == nil else { return }
            let engine = AVAudioEngine()
            let silence = Self.makeSilence()
            engine.attach(silence)
            engine.connect(silence, to: engine.mainMixerNode, format: engine.outputNode.inputFormat(forBus: 0))
            do {
                try engine.start()
                self.engine = engine
            } catch {
                engine.detach(silence)
            }
        }
    }

    func stop() {
        wanted = false
        engine?.stop()
        engine = nil
    }

    /// After the system resets its media services the old engine is dead; build a new one if
    /// the silence is still wanted.
    func restart() {
        let wasWanted = wanted
        stop()
        activationStarted = nil
        if wasWanted { start() }
    }

    @concurrent
    private nonisolated static func activateSession() async {
        let session = AVAudioSession.sharedInstance()
        if #available(iOS 27, *) {
            _ = try? await session.activate(options: [])
        } else {
            try? session.setActive(true)
        }
    }

    /// The render block runs on the real-time audio thread, so it must not be actor-isolated.
    private nonisolated static func makeSilence() -> AVAudioSourceNode {
        AVAudioSourceNode { _, _, _, bufferList in
            for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
    }
}
