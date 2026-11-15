import SwiftUI

struct PlayerView: View {
    @Environment(PlayerController.self) private var player
    @Environment(ProcessingQueue.self) private var processing
    @Environment(\.dismiss) private var dismiss

    private let rates: [Float] = [0.8, 1, 1.2, 1.5, 1.75, 2]
    private let sleepOptions: [SleepTimer?] = [nil, .minutes(15), .minutes(30), .minutes(45), .minutes(60), .endOfEpisode]

    /// Pages swiped through in place of the artwork. Swiping right from the artwork shows the
    /// transcript, swiping left shows the player settings.
    private enum Page: CaseIterable {
        case transcript, artwork, settings
    }

    /// Back to the artwork each time the player opens.
    @State private var page = Page.artwork
    @State private var showingNotes = false
    @State private var showingChapters = false

    var body: some View {
        VStack(spacing: 20) {
            Capsule().fill(.tertiary).frame(width: 40, height: 5).padding(.top, 8)

            if let episode = player.episode {
                filteredCount(episode)
                    .opacity(page == .transcript ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: page)

                // The pages fill the room above the title: the transcript uses all of it, while the artwork
                // and settings are centered in it.
                TabView(selection: $page) {
                    transcriptPage(episode).tag(Page.transcript)
                    artworkPage(episode)
                        .padding(.vertical, 20) // room for the shadow; the page view clips
                        .frame(maxHeight: .infinity, alignment: .center)
                        .tag(Page.artwork)
                    settingsPage
                        .frame(maxHeight: .infinity, alignment: .center)
                        .tag(Page.settings)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(minHeight: 320, maxHeight: .infinity)

                pageIndicator

                VStack(spacing: 6) {
                    Text(episode.title)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    Text(episode.show?.title ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let chapter = player.currentChapter {
                        Button { showingChapters = true } label: {
                            Label(chapter.title, systemImage: "list.bullet")
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Chapter: \(chapter.title)")
                        .accessibilityHint("Shows all chapters")
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
                .sheet(isPresented: $showingChapters) { ChaptersView() }

                ScrubberView(
                    currentTime: player.currentTime,
                    duration: player.duration,
                    playableLimit: player.playableLimit,
                    isFullyScanned: player.isFullyScanned,
                    muteMarkers: page == .transcript ? player.mutedRanges : [],
                    onSeek: player.seek(to:)
                )
                .padding(.horizontal, 24)
                .animation(.easeOut(duration: 0.2), value: page)

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

                HStack(spacing: 44) {
                    Button { player.skip(by: -15) } label: {
                        Image(systemName: "gobackward.15").font(.system(size: 30))
                    }
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .accentCircleSymbol()
                            .font(.system(size: 68))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    Button { player.skip(by: 30) } label: {
                        Image(systemName: "goforward.30").font(.system(size: 30))
                    }
                }
                .buttonStyle(.plain)
                .padding(.bottom, 12)
                .sheet(isPresented: $showingNotes) { ShowNotesView(episode: episode) }
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "play.slash")
            }
        }
        .presentationDragIndicator(.hidden)
        .onChange(of: player.episode?.id) { page = .artwork }
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
        Button { showingNotes = true } label: {
            ArtworkView(urlStrings: episode.artworkCandidates, size: 280, cornerRadius: 20)
                .shadow(radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Artwork")
        .accessibilityHint("Shows the show notes")
    }

    /// Centered like the artwork when it fits; scrolls on small screens.
    private var settingsPage: some View {
        ViewThatFits(in: .vertical) {
            settingsContent
            ScrollView { settingsContent }
                .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var settingsContent: some View {
        VStack(spacing: 14) {
            Label("Playback Speed", systemImage: "speedometer")
                .font(.headline)
            optionGrid {
                ForEach(rates, id: \.self) { rate in
                    optionButton(rateLabel(rate), isSelected: player.rate == rate) { player.setRate(rate) }
                        .accessibilityLabel("\(rateLabel(rate)) speed")
                }
            }
            Text("Remembered for each show.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Label("Sleep Timer", systemImage: "moon.zzz")
                .font(.headline)
                .padding(.top, 10)
            optionGrid {
                ForEach(sleepOptions, id: \.self) { option in
                    optionButton(sleepLabel(option), isSelected: player.sleepTimer == option) {
                        player.setSleepTimer(option)
                    }
                    .accessibilityLabel(option == nil ? "Sleep timer off" : "Sleep \(sleepLabel(option))")
                }
            }
            Group {
                if let timer = player.sleepTimer {
                    Text(sleepStatus(timer)).monospacedDigit()
                } else {
                    Text("Counts only while audio plays.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 12)
    }

    private func optionGrid(@ViewBuilder content: () -> some View) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10, content: content)
    }

    private func optionButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.onAccent) : AnyShapeStyle(.tint))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tint.opacity(0.12)),
                    in: .capsule
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func sleepLabel(_ option: SleepTimer?) -> String {
        switch option {
        case nil: "Off"
        case .minutes(let minutes): "\(minutes) min"
        case .endOfEpisode: "End of Ep."
        }
    }

    private func sleepStatus(_ timer: SleepTimer) -> String {
        switch timer {
        case .minutes: "Sleeps in \(Format.clock(player.sleepRemaining))"
        case .endOfEpisode: "Sleeps at end of episode"
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(Page.allCases, id: \.self) { item in
                Button {
                    withAnimation { page = item }
                } label: {
                    Circle()
                        .fill(item == page ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .frame(width: 7, height: 7)
                        .padding(4)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pageName(item))
                .accessibilityAddTraits(item == page ? .isSelected : [])
            }
        }
    }

    private func pageName(_ page: Page) -> String {
        switch page {
        case .transcript: "Transcript"
        case .artwork: "Artwork"
        case .settings: "Player settings"
        }
    }

    private func rateLabel(_ rate: Float) -> String {
        rate == 1 ? "1×" : String(format: "%g×", rate)
    }
}

/// The current episode's chapters. Tapping one plays from its start.
struct ChaptersView: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(player.chapters) { chapter in
                    let isCurrent = chapter.id == player.currentChapter?.id
                    Button {
                        player.seek(to: chapter)
                        dismiss()
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
                    .id(chapter.id)
                    .accessibilityLabel("\(chapter.title), \(Format.clock(chapter.start))")
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                }
                .onAppear {
                    if let id = player.currentChapter?.id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .navigationTitle("Chapters")
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

    /// Built from the HTML once the sheet appears; the HTML importer is too slow for `body`.
    @State private var notes: AttributedString?

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Show Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task(id: episode.episodeID) { notes = ShowNotes.attributed(episode.summary) }
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
        return Text(attributed(line))
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

    private func accessibilityText(_ line: TranscriptLine) -> String {
        let text = line.words.compactMap { word -> String? in
            if word.isSkipMarker { return "skipped crosstalk" }
            if word.isMuted { return "muted" }
            return word.isSkipped ? nil : word.text
        }.joined(separator: " ")
        return "\(Format.clock(line.start)), \(text)"
    }
}
