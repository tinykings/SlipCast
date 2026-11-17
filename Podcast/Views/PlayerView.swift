import AVFoundation
import AVKit
import Combine
import SwiftUI

struct PlayerView: View {
    @Environment(PlayerController.self) private var player
    @Environment(ProcessingQueue.self) private var processing
    @Environment(\.dismiss) private var dismiss

    /// 0.5× to 3× in steps of 0.05, with a tick every 0.25.
    private let rates: [Float] = (10...60).map { Float($0) / 20 }
    private let sleepOptions: [SleepTimer?] = [
        nil, .minutes(5), .minutes(10), .minutes(15), .minutes(20), .minutes(30),
        .minutes(45), .minutes(60), .minutes(90), .endOfEpisode,
    ]
    /// Where the sleep timer slider is while it's being dragged. The timer is set when it's let go.
    @State private var sleepDragIndex: Int?

    /// What the player shows. On the artwork the player is full size; every other section takes
    /// over the space above the controls, with a compact header for the episode at the top.
    /// Tapping a section's button again, or the compact header, goes back to the artwork.
    private enum Page {
        case artwork, notes, chapters, transcript, settings
    }

    /// Back to the artwork each time the player opens.
    @State private var page = Page.artwork

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(.tertiary).frame(width: 40, height: 5).padding(.top, 8)

            if let episode = player.episode {
                Group {
                    if page == .artwork {
                        fullLayout(episode)
                    } else {
                        compactLayout(episode)
                    }
                }
                .transition(.opacity)

                scanStatus

                transportControls

                VStack(spacing: 10) {
                    if page == .artwork { OutputRouteLabel() }
                    actionBar
                }
                .padding(.bottom, 8)
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "play.slash")
            }
        }
        .presentationDragIndicator(.hidden)
        .onChange(of: player.episode?.id) { page = .artwork }
    }

    private func show(_ section: Page) {
        withAnimation(.easeInOut(duration: 0.25)) { page = page == section ? .artwork : section }
    }

    // MARK: - Layouts

    @ViewBuilder
    private func fullLayout(_ episode: Episode) -> some View {
        artworkPage(episode)
            .padding(.vertical, 20)
            .frame(minHeight: 240, maxHeight: .infinity, alignment: .center)

        VStack(spacing: 6) {
            Text(episode.title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Text(episode.show?.title ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let chapter = player.currentChapter {
                Text(chapter.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                    .accessibilityLabel("Chapter: \(chapter.title)")
            }
            HStack(spacing: 12) {
                if !player.upNext.isEmpty {
                    Label("\(player.upNext.count) up next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                if let timer = player.sleepTimer {
                    Label(sleepStatus(timer), systemImage: "moon.zzz.fill")
                        .monospacedDigit()
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)

        ScrubberView(
            currentTime: player.currentTime,
            duration: player.duration,
            playableLimit: player.playableLimit,
            isFullyScanned: player.isFullyScanned,
            onSeek: player.seek(to:)
        )
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func compactLayout(_ episode: Episode) -> some View {
        compactHeader(episode)

        if page == .transcript {
            filteredCount(episode)
        }

        Group {
            switch page {
            case .notes:
                ShowNotesContent(episode: episode)
            case .chapters:
                ChapterList()
            case .transcript:
                transcriptPage(episode)
            case .settings:
                settingsPage
                    .frame(maxHeight: .infinity, alignment: .top)
            case .artwork:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Small artwork, show, title, and a thin progress bar. Tapping it goes back to the artwork.
    private func compactHeader(_ episode: Episode) -> some View {
        Button { show(.artwork) } label: {
            HStack(spacing: 14) {
                ArtworkView(urlStrings: episode.artworkCandidates, size: 64, cornerRadius: 10)
                    .shadow(radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.show?.title ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(episode.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    CompactProgressBar(
                        currentTime: player.currentTime,
                        duration: player.duration,
                        muteMarkers: page == .transcript ? player.mutedRanges : []
                    )
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(episode.title)
        .accessibilityValue("\(Format.clock(player.currentTime)) of \(Format.clock(player.duration))")
        .accessibilityHint("Shows the artwork")
    }

    @ViewBuilder
    private var scanStatus: some View {
        if let error = player.scanError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.horizontal)
        } else if player.isWaitingForScan {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(player.scanStatus)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    /// Smaller while a section is open, so the section gets more room.
    private var transportControls: some View {
        let compact = page != .artwork
        let hasChapters = !player.chapters.isEmpty
        return HStack(spacing: hasChapters ? 26 : 44) {
            if hasChapters {
                chapterSkipButton(forward: false, isEnabled: player.previousChapter != nil) {
                    player.skipToPreviousChapter()
                }
            }
            Button { player.skip(by: -15) } label: {
                Image(systemName: "gobackward.15").font(.system(size: compact ? 24 : 30))
            }
            .accessibilityLabel("Back 15 seconds")
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .accentCircleSymbol()
                    .font(.system(size: compact ? 52 : 68))
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { player.skip(by: 30) } label: {
                Image(systemName: "goforward.30").font(.system(size: compact ? 24 : 30))
            }
            .accessibilityLabel("Forward 30 seconds")
            if hasChapters {
                chapterSkipButton(forward: true, isEnabled: player.nextChapter != nil) {
                    player.skipToNextChapter()
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Show notes, chapters, AirPlay, transcript, and settings, left to right.
    private var actionBar: some View {
        HStack(spacing: 0) {
            actionButton("Show Notes", systemImage: "doc.text", isSelected: page == .notes) { show(.notes) }
            Spacer(minLength: 8)
            actionButton("Chapters", systemImage: "list.bullet", isSelected: page == .chapters,
                         isEnabled: !player.chapters.isEmpty) { show(.chapters) }
            Spacer(minLength: 8)
            RoutePickerButton()
                .frame(width: 56, height: 56)
                .background(.fill.tertiary, in: .circle)
            Spacer(minLength: 8)
            actionButton("Transcript", systemImage: "quote.bubble", isSelected: page == .transcript) {
                show(.transcript)
            }
            Spacer(minLength: 8)
            actionButton("Player Settings", systemImage: "gearshape", isSelected: page == .settings) {
                show(.settings)
            }
        }
        .padding(.horizontal, 24)
    }

    private func actionButton(_ title: String, systemImage: String, isSelected: Bool = false,
                              isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.onAccent) : AnyShapeStyle(.primary))
                .frame(width: 56, height: 56)
                .background(
                    isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.fill.tertiary),
                    in: .circle
                )
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Jumps to the start of the next chapter, or back to the start of this or the previous one.
    private func chapterSkipButton(forward: Bool, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: forward ? "forward.end.fill" : "backward.end.fill")
                .font(.system(size: 22))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.3)
        .accessibilityLabel(forward ? "Next chapter" : "Previous chapter")
    }

    private func filteredCount(_ episode: Episode) -> some View {
        Group {
            if episode.requiresFiltering {
                Label(
                    player.mutedSpotCount == 1 ? "1 filtered section" : "\(player.mutedSpotCount) filtered sections",
                    systemImage: "speaker.slash.fill"
                )
                .foregroundStyle(.tint)
            } else {
                Label("Filtering off", systemImage: "speaker.wave.2")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline.weight(.semibold))
        .frame(minHeight: 22)
    }

    @ViewBuilder
    private func transcriptPage(_ episode: Episode) -> some View {
        if episode.requiresFiltering {
            TranscriptView(
                lines: player.transcriptLines,
                currentTime: player.currentTime,
                playableLimit: player.playableLimit,
                isFullyScanned: player.isFullyScanned,
                onSeek: player.seek(to:)
            )
        } else {
            switch player.publisherTranscript {
            case .loaded(let lines):
                TranscriptView(
                    lines: lines,
                    currentTime: player.currentTime,
                    playableLimit: player.playableLimit,
                    isFullyScanned: true,
                    onSeek: player.seek(to:)
                )
            case .loading:
                ProgressView()
            case .none, .failed:
                readAlongPage(episode)
            }
        }
    }

    /// The transcript made on this device, for unfiltered episodes without one from the feed.
    @ViewBuilder
    private func readAlongPage(_ episode: Episode) -> some View {
        if !DeviceSupport.transcriptionAvailable {
            transcriptMessage("This episode doesn’t come with a transcript, and this device can’t make one.")
        } else if episode.downloadState != .downloaded {
            transcriptMessage("A transcript is made on this device once the episode finishes downloading.")
        } else if player.readAlongFailed && player.readAlongLines.isEmpty {
            transcriptMessage("Couldn’t make a transcript for this episode.")
        } else if processing.isPaused && player.readAlongLines.isEmpty {
            VStack(spacing: 4) {
                transcriptMessage("Transcribing is paused.")
                Button("Resume") { processing.resumeProcessing() }
                    .buttonStyle(.bordered)
            }
        } else {
            TranscriptView(
                lines: player.readAlongLines,
                currentTime: player.currentTime,
                playableLimit: .infinity,
                isFullyScanned: player.readAlongThrough == .infinity,
                onSeek: player.seek(to:)
            )
        }
    }

    private func transcriptMessage(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(32)
    }

    private func artworkPage(_ episode: Episode) -> some View {
        Button { show(.notes) } label: {
            ArtworkView(urlStrings: episode.artworkCandidates, size: 280, cornerRadius: 20)
                .shadow(radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Artwork")
        .accessibilityHint("Shows the show notes")
    }

    /// Scrolls on small screens.
    private var settingsPage: some View {
        ViewThatFits(in: .vertical) {
            settingsContent
            ScrollView { settingsContent }
                .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var settingsContent: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Audio Settings")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                scopeMenu
            }
            .padding(.horizontal, 4)

            settingCard("Speed", systemImage: "gauge.with.dots.needle.33percent", value: rateLabel(player.rate)) {
                SteppedSlider(
                    count: rates.count,
                    selection: Binding(
                        get: { nearestRateIndex(player.rate) },
                        set: { player.setRate(rates[$0]) }
                    ),
                    tickEvery: 5,
                    accessibilityLabel: "Speed",
                    valueText: { rateLabel(rates[$0]) }
                )
            }

            settingCard("Sleep Timer", systemImage: "moon", value: sleepValue) {
                SteppedSlider(
                    count: sleepOptions.count,
                    selection: Binding(
                        get: { sleepDragIndex ?? sleepIndex(player.sleepTimer) },
                        set: { sleepDragIndex = $0 }
                    ),
                    accessibilityLabel: "Sleep timer",
                    valueText: { sleepLabel(sleepOptions[$0]) },
                    onEditingEnded: {
                        if let index = sleepDragIndex { player.chooseSleepTimer(sleepOptions[index]) }
                        sleepDragIndex = nil
                    }
                )
            }

            Text(scopeFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Whether the speed and sleep timer are this show's own or the defaults for all shows.
    private var scopeMenu: some View {
        Menu {
            Picker("Settings For", selection: Binding(
                get: { player.settingsScope },
                set: { player.setSettingsScope($0) }
            )) {
                Text("This Show").tag(PlaybackSettingsScope.thisShow)
                Text("All Shows").tag(PlaybackSettingsScope.allShows)
            }
        } label: {
            HStack(spacing: 4) {
                Text(player.settingsScope == .thisShow ? "This Show" : "All Shows")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .contentShape(.rect)
        }
        .disabled(player.episode?.show == nil)
        .accessibilityLabel("Settings apply to")
        .accessibilityValue(player.settingsScope == .thisShow ? "This show" : "All shows")
    }

    private var scopeFootnote: String {
        if player.settingsScope == .thisShow, let title = player.episode?.show?.title {
            return "Speed and sleep timer apply only to \(title)."
        }
        return "Speed and sleep timer are the defaults for every show without its own."
    }

    private func settingCard(_ title: String, systemImage: String, value: String,
                             @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label {
                    Text(title).font(.headline)
                } icon: {
                    Image(systemName: systemImage).foregroundStyle(.secondary)
                }
                Spacer()
                Text(value)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            content()
        }
        .padding(16)
        .background(.fill.tertiary, in: .rect(cornerRadius: 22))
    }

    private var sleepValue: String {
        if let sleepDragIndex { return sleepLabel(sleepOptions[sleepDragIndex]) }
        switch player.sleepTimer {
        case nil: return "Off"
        case .minutes: return "\(Format.clock(player.sleepRemaining)) left"
        case .endOfEpisode: return "End of episode"
        }
    }

    private func nearestRateIndex(_ rate: Float) -> Int {
        rates.indices.min { abs(rates[$0] - rate) < abs(rates[$1] - rate) } ?? 0
    }

    private func sleepIndex(_ timer: SleepTimer?) -> Int {
        sleepOptions.firstIndex(of: timer) ?? sleepOptions.indices.last { index in
            // A timer not on the slider (e.g. from an older version) shows at the nearest stop below.
            if case .minutes(let minutes) = timer, case .minutes(let option) = sleepOptions[index] {
                return option <= minutes
            }
            return false
        } ?? 0
    }

    private func sleepLabel(_ option: SleepTimer?) -> String {
        switch option {
        case nil: "Off"
        case .minutes(let minutes): "\(minutes) min"
        case .endOfEpisode: "End of episode"
        }
    }

    private func sleepStatus(_ timer: SleepTimer) -> String {
        switch timer {
        case .minutes: "Sleeps in \(Format.clock(player.sleepRemaining))"
        case .endOfEpisode: "Sleeps at end of episode"
        }
    }

    private func rateLabel(_ rate: Float) -> String {
        rate == 1 ? "1×" : String(format: "%g×", (rate * 100).rounded() / 100)
    }
}

/// A slider that snaps to `count` evenly spaced stops, with dots under the track marking every
/// `tickEvery`th one. Dragging anywhere on it moves the thumb.
struct SteppedSlider: View {
    let count: Int
    @Binding var selection: Int
    var tickEvery = 1
    let accessibilityLabel: String
    let valueText: (Int) -> String
    var onEditingEnded: () -> Void = {}

    private let thumbSize = CGSize(width: 52, height: 30)
    private let trackHeight: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let usable = max(geometry.size.width - thumbSize.width, 1)
            let thumbCenter = thumbSize.width / 2 + usable * fraction(selection)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: thumbCenter, height: trackHeight)
                ForEach(Array(stride(from: 0, to: count, by: max(tickEvery, 1))), id: \.self) { index in
                    Circle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 3, height: 3)
                        .position(x: thumbSize.width / 2 + usable * fraction(index), y: thumbSize.height / 2 + 13)
                }
                Capsule()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    .frame(width: thumbSize.width, height: thumbSize.height)
                    .offset(x: thumbCenter - thumbSize.width / 2)
            }
            .frame(height: thumbSize.height)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let position = (value.location.x - thumbSize.width / 2) / usable
                        let index = Int((min(max(position, 0), 1) * CGFloat(count - 1)).rounded())
                        if index != selection { selection = index }
                    }
                    .onEnded { _ in onEditingEnded() }
            )
            .animation(.interactiveSpring(duration: 0.2), value: selection)
        }
        .frame(height: thumbSize.height + 12)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(valueText(selection))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: selection = min(selection + 1, count - 1)
            case .decrement: selection = max(selection - 1, 0)
            @unknown default: return
            }
            onEditingEnded()
        }
    }

    private func fraction(_ index: Int) -> CGFloat {
        count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0
    }
}

/// The current episode's chapters, shown in the player. Tapping one plays from its start.
struct ChapterList: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        ScrollViewReader { proxy in
            List(player.chapters) { chapter in
                let isCurrent = chapter.id == player.currentChapter?.id
                Button {
                    player.seek(to: chapter)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundStyle(.tint)
                            .opacity(isCurrent ? 1 : 0)
                            .accessibilityHidden(true)
                        Text(chapter.title)
                            .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text(Format.clock(chapter.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .id(chapter.id)
                .accessibilityLabel("\(chapter.title), \(Format.clock(chapter.start))")
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onAppear {
                if let id = player.currentChapter?.id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

struct MiniPlayerView: View {
    @Environment(PlayerController.self) private var player
    /// Called when the episode pill is tapped. This only opens the player; it never starts playback.
    let onOpen: () -> Void

    private let height: CGFloat = 64

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                stopButton
                episodePill
                playPauseButton
            }
        }
    }

    private var episodePill: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    ArtworkView(urlStrings: player.episode?.artworkCandidates ?? [], size: 44, cornerRadius: 8)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.episode?.title ?? "")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("\(Format.clock(player.currentTime)) / \(Format.clock(player.duration))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if player.isWaitingForScan {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(player.episode?.title ?? "Now playing")
            .accessibilityValue("\(Format.clock(player.currentTime)) of \(Format.clock(player.duration))")
            .accessibilityHint("Opens the player")
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(height: height)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var stopButton: some View {
        Button { player.stop() } label: {
            Image(systemName: "xmark")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: height, height: height)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Stop playback")
    }

    private var playPauseButton: some View {
        Button { player.togglePlayPause() } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.title2)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: height, height: height)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }
}

struct ShowNotesView: View {
    let episode: Episode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ShowNotesContent(episode: episode)
                .navigationTitle("Show Notes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// An episode's title and show notes, scrolling. Used in the show notes sheet and in the player.
struct ShowNotesContent: View {
    let episode: Episode

    /// Built from the HTML once this appears; the HTML importer is too slow for `body`.
    @State private var notes: AttributedString?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(episode.title)
                    .font(.title3.bold())
                if let notes {
                    if notes.characters.isEmpty {
                        Text("This episode has no show notes.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(notes)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .task(id: episode.episodeID) { notes = ShowNotes.attributed(episode.summary) }
    }
}

/// A thin, display-only progress bar for the player's compact header.
struct CompactProgressBar: View {
    let currentTime: Double
    let duration: Double
    var muteMarkers: [ClosedRange<Double>] = []

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: width * fraction(currentTime))
                ForEach(muteMarkers, id: \.lowerBound) { range in
                    let start = width * fraction(range.lowerBound)
                    let markerWidth = max(2, width * fraction(range.upperBound) - start)
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: markerWidth)
                        .offset(x: min(start, width - markerWidth))
                }
            }
        }
        .frame(height: 5)
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }

    private func fraction(_ time: Double) -> Double {
        guard duration > 0, time.isFinite else { return 0 }
        return min(1, max(0, time / duration))
    }
}

/// Progress bar that also shows how much of the episode has been scanned. You can't seek past
/// the scanned part. Dense overlap detection may run slower than playback.
struct ScrubberView: View {
    let currentTime: Double
    let duration: Double
    let playableLimit: Double
    let isFullyScanned: Bool
    /// Muted spots to mark on the bar; empty to hide them.
    var muteMarkers: [ClosedRange<Double>] = []
    let onSeek: (Double) -> Void

    @State private var dragTime: Double?

    var body: some View {
        let shown = dragTime ?? currentTime
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    if !isFullyScanned {
                        Capsule()
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: width * fraction(playableLimit))
                    }
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: width * fraction(shown))
                }
                .frame(height: dragTime == nil ? 6 : 10)
                .overlay(alignment: .leading) {
                    ForEach(muteMarkers, id: \.lowerBound) { range in
                        let start = width * fraction(range.lowerBound)
                        let markerWidth = max(3, width * fraction(range.upperBound) - start)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.red)
                            .frame(width: markerWidth, height: 16)
                            .offset(x: min(start, width - markerWidth))
                    }
                    .allowsHitTesting(false)
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let time = value.location.x / max(width, 1) * duration
                            dragTime = min(max(0, time), playableLimit)
                        }
                        .onEnded { _ in
                            if let dragTime { onSeek(dragTime) }
                            dragTime = nil
                        }
                )
                .animation(.easeOut(duration: 0.15), value: dragTime == nil)
            }
            .frame(height: 24)

            HStack {
                Text(Format.clock(shown))
                Spacer()
                if !isFullyScanned {
                    Text("Scanned to \(Format.clock(playableLimit))")
                    Spacer()
                }
                Text("-" + Format.clock(duration - shown))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Format.clock(currentTime)) of \(Format.clock(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(currentTime + 30)
            case .decrement: onSeek(currentTime - 15)
            @unknown default: break
            }
        }
    }

    private func fraction(_ time: Double) -> Double {
        guard duration > 0, time.isFinite else { return 0 }
        return min(1, max(0, time / duration))
    }
}

/// The transcript found so far, following playback. Lines with a muted word or skipped passage
/// are highlighted, muted words are masked, and skipped passages are marked. Tapping a line jumps there.
struct TranscriptView: View {
    let lines: [TranscriptLine]
    let currentTime: Double
    let playableLimit: Double
    let isFullyScanned: Bool
    let onSeek: (Double) -> Void

    /// Set while the user scrolls by hand, so following playback doesn't yank them back.
    @State private var userScrolledAt: Date?

    private var currentLineID: Int? {
        lines.last(where: { $0.start <= currentTime })?.id
    }

    var body: some View {
        if lines.isEmpty {
            VStack(spacing: 10) {
                if isFullyScanned {
                    Text("No words were found in this episode.")
                } else {
                    ProgressView()
                    Text("The transcript appears as the episode is scanned.")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(lines) { line in
                            row(line, isCurrent: line.id == currentLineID)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.06),
                            .init(color: .black, location: 0.94),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting { userScrolledAt = .now }
                }
                .onAppear {
                    if let currentLineID { proxy.scrollTo(currentLineID, anchor: .center) }
                }
                .onChange(of: currentLineID) { _, id in
                    guard let id else { return }
                    if let userScrolledAt, Date.now.timeIntervalSince(userScrolledAt) < 5 { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func row(_ line: TranscriptLine, isCurrent: Bool) -> some View {
        let isMuted = line.containsMutedWord
        let canSeek = line.start <= playableLimit
        return Text(line.isMusic ? musicText(line) : attributed(line))
            .font(.callout)
            .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if isMuted {
                    RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(isCurrent ? 0.22 : 0.12))
                }
            }
            .contentShape(.rect)
            .onTapGesture {
                guard canSeek else { return }
                userScrolledAt = nil
                onSeek(line.start)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText(line))
            .accessibilityAddTraits(canSeek ? .isButton : [])
            .accessibilityHint(canSeek ? "Plays from here" : "")
    }

    private func attributed(_ line: TranscriptLine) -> AttributedString {
        var result = AttributedString()
        for (index, word) in line.words.enumerated() {
            if index > 0 { result += AttributedString(" ") }
            if word.isSkipMarker {
                var marker = AttributedString("▸▸ skipped")
                marker.foregroundColor = .red
                marker.inlinePresentationIntent = .stronglyEmphasized
                result += marker
            } else if word.isMuted {
                var masked = AttributedString(MuteMatcher.mask(word.text))
                masked.foregroundColor = .red
                masked.inlinePresentationIntent = .stronglyEmphasized
                result += masked
            } else if word.isSkipped {
                var skipped = AttributedString(word.text)
                skipped.foregroundColor = .red.opacity(0.7)
                skipped.strikethroughStyle = .single
                result += skipped
            } else {
                result += AttributedString(word.text)
            }
        }
        return result
    }

    private func musicText(_ line: TranscriptLine) -> AttributedString {
        var text = AttributedString("♪ Music · \(Int((line.end - line.start).rounded())) sec")
        text.foregroundColor = .accentColor
        text.inlinePresentationIntent = .stronglyEmphasized
        return text
    }

    private func accessibilityText(_ line: TranscriptLine) -> String {
        if line.isMusic {
            return "\(Format.clock(line.start)), music, \(Int((line.end - line.start).rounded())) seconds"
        }
        let text = line.words.compactMap { word -> String? in
            if word.isSkipMarker { return "skipped crosstalk" }
            if word.isMuted { return "muted" }
            return word.isSkipped ? nil : word.text
        }.joined(separator: " ")
        return "\(Format.clock(line.start)), \(text)"
    }
}

/// The system AirPlay picker, for sending audio to speakers, TVs, and headphones.
struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = .label
        view.activeTintColor = .tintColor
        view.accessibilityLabel = "AirPlay"
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// Where audio is playing right now, such as "iPhone" or a speaker's name. Follows route changes.
struct OutputRouteLabel: View {
    @State private var output = Self.currentOutput()

    var body: some View {
        Label(output?.portName ?? "iPhone", systemImage: Self.symbol(for: output?.portType ?? .builtInSpeaker))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityLabel("Playing on \(output?.portName ?? "iPhone")")
            .onReceive(
                NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
                    .receive(on: DispatchQueue.main)
            ) { _ in output = Self.currentOutput() }
    }

    private static func currentOutput() -> AVAudioSessionPortDescription? {
        AVAudioSession.sharedInstance().currentRoute.outputs.first
    }

    private static func symbol(for port: AVAudioSession.Port) -> String {
        switch port {
        case .airPlay: "airplay.audio"
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones: "headphones"
        case .carAudio: "car"
        case .HDMI: "tv"
        default: "iphone"
        }
    }
}
