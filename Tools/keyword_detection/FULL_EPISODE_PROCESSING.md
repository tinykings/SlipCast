# Downloaded episode processing

Filtering is selected on each subscribed show's detail screen with **Filter muted words**.
It defaults off, including for existing shows after migration. Global Muted Words settings
only affect enabled shows. No separate model download is needed for the overlap detector.

**Filtering off:** episodes play the original audio, with no audio tap, transcription,
automatic overlap scan or saved reviewed mutes applied. They can stream or download.
Unfiltered downloads become ready as soon as the file finishes downloading. The app remains
usable without Apple's SpeechTranscriber hardware support.

**Filtering on:** episodes must download completely, then finish Apple transcription and
the dense overlap pass before playback is allowed. Filtered episodes cannot create a
StreamingSession, and their play control is unavailable until both passes complete.
The acoustic pass uses individual English words from Settings → Muted Words; phrases and
other languages keep transcript matching. SpeechTranscriber support is required to enable
filtering on a device. Audio remains on the device and the source file is unchanged.

Automatic hits, transcript matches, and independently saved reviewed mutes are combined in
the normal player's tap. There is no manual Apply step for automatic results. Padding can
be adjusted without re-running inference. The player shows Filtering off for original audio.

## Processing and playback

- Show settings explain the active mode. Changing mode stops that show's current playback.
  Enabling filtering cancels an active original-audio stream and switches it to a full download.
- Downloads shows Transcribing, model preparation, then Checking overlapping voices, including a fractional percentage
  and scanned time. Ready to Play requires both passes for filtered shows.
- Downloads has Pause/Resume filtering. Pausing persists across launches and preserves each
  completed checkpoint. Background requests and automatic starts respect the pause.
- Playback and seeking into partially processed filtered episodes are blocked. Previously
  saved listening positions are retained for when full processing finishes.
- Only downloaded episodes from enabled shows enter the processing queue. Existing downloads
  are queued when filtering is enabled; historical episodes are not downloaded in bulk.
- Completed Apple transcripts are reused on interruption. Each finished acoustic alignment
  saves hits and the next window index. Relaunch/background work resumes there. iOS controls
  background execution; keeping the app open gives it time to make progress.
- A checkpoint is tied to detector version, audio fingerprint and normalized target words.
  Changing words rechecks enabled shows; changing padding does not. Neither affects playback
  of shows with filtering off.
- Re-scan filtered downloads clears automatic work and transcripts only for enabled shows,
  preserving reviewed mutes. It does not pause original-audio playback. Download removal
  cancels processing and removes checkpoints.

## Algorithm

A 15-second separation window advances one second at a time. It is separated once for
all target words. One keyword spotter with all target labels scans the original and each
separated voice. Its short streams retain the timestamp-reset workaround used by the
preview. A future alignment cannot start before the saved next-window time. Playback still requires
completion of the whole filtered episode in this first integration. Completion includes
all remaining audio at EOF. Only a window of PCM, model state and hit list are held in RAM.
No full-length PCM or original/filtered preview files are created by automatic scanning.

The detector yields between alignments so cancellation or the test screen can run.
Removing a download cancels its worker and cleans up again after it stops, preventing
an in-flight checkpoint write from recreating removed files. Rescan requests likewise
clear checkpoints again after the cancelled worker exits.

## Validation

`full_episode_results.json` records a completed 40-second representative excerpt (including
the overlapping swear) with multiple keyword targets, plus interrupted/resumed work on the
63-minute source file. The long file was deliberately stopped after ten windows; a whole
long episode has not been run to completion. CPU cost is substantial and this build is for
preparing downloads, not a proven real-time filter. Benchmark times are debug Mac results,
not measured iPhone throughput, power use or temperature.

Native tests:

```
swift test --package-path Packages/AudioDetection --filter 'AudioDetectionTests|ReviewedMuteStoreTests|EpisodeAudioScanTests'
```

App integration tests use cached synthetic transcripts, synthetic control audio, an
in-memory SwiftData container, and the real native detector/player. They verify automatic
mutes without a transcript match or manual Apply, preservation of reviewed ranges, word-list
invalidation and playback gating, download/model deletion during inference, default-off show
settings, no streaming for filtered episodes, original-audio playback ignoring saved mutes,
and cancellation when show filtering is disabled.

```
xcodebuild -project SlipCast.xcodeproj -scheme SlipCast \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID' test
```

Standalone full-file probe (last argument optionally stops at a saved window index):

```
swift run --package-path Packages/AudioDetection DetectionProbe \
  --episode AUDIO 'fuck,another' REPORT.json CHECKPOINT_DIRECTORY [STOP_AFTER_WINDOW]
```

Run it again with the same file, targets and checkpoint directory to resume. Podcast
excerpts used for investigation are not bundled into the app or test suite.

## Performance follow-up

A 0% label with 28 seconds checked on a 73-minute episode was progress hidden by integer
rounding. Progress now uses one decimal place and reports model preparation separately.
Accelerate vector operations replace scalar Swift loops for downmixing, extracting voices
and normalizing levels, without reducing the dense alignments that recovered the overlap.
The model itself remains expensive; this is not a demonstrated solution for fast full-hour
processing. See `performance_investigation.json`. Hardware-acceleration and release-build
measurements were not controlled enough to claim a speed gain; CPU remains the app default.
A future targeted overlap pass or smaller separator must be validated against the missed
interruption before being used to skip work. The standalone probe accepts `--accelerated`
for investigation, not as an app setting. Existing checkpoints remain compatible.
