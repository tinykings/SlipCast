import SwiftUI

struct PlayerView: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss

    private let rates: [Float] = [0.8, 1, 1.2, 1.5, 1.75, 2]

    /// Pages swiped through in place of the artwork. Swiping right from the artwork shows the
    /// transcript, swiping left shows the player settings.
    private enum Page: CaseIterable {
        case transcript, artwork, settings
    }

    /// Back to the artwork each time the player opens.
    @State private var page = Page.artwork
    @State private var showingNotes = false

    var body: some View {
        VStack(spacing: 20) {
            Capsule().fill(.tertiary).frame(width: 40, height: 5).padding(.top, 8)

            if let episode = player.episode {
                filteredCount(episode)
                    .opacity(page == .transcript ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: page)

                Spacer(minLength: 0)

                TabView(selection: $page) {
                    transcriptPage(episode).tag(Page.transcript)
                    artworkPage(episode).tag(Page.artwork)
                    settingsPage.tag(Page.settings)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 320)

                pageIndicator

                VStack(spacing: 6) {
                    Text(episode.title)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    Text(episode.show?.title ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !player.upNext.isEmpty {
                        Label("\(player.upNext.count) up next", systemImage: "text.line.first.and.arrowtriangle.forward")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)

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
            Text("Turn on filtering in this show’s settings to see its transcript.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(32)
        }
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

    private var settingsPage: some View {
        VStack(spacing: 14) {
            Label("Playback Speed", systemImage: "speedometer")
                .font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(rates, id: \.self) { rate in
                    let isSelected = player.rate == rate
                    Button { player.rate = rate } label: {
                        Text(rateLabel(rate))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(isSelected ? AnyShapeStyle(Color.onAccent) : AnyShapeStyle(.tint))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(
                                isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tint.opacity(0.12)),
                                in: .capsule
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(rateLabel(rate)) speed")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .padding(.horizontal, 40)
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

struct MiniPlayerView: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(urlStrings: player.episode?.artworkCandidates ?? [], size: 32, cornerRadius: 6)
            Text(player.episode?.title ?? "")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer()
            if player.isWaitingForScan {
                ProgressView().controlSize(.small)
            }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            Button { player.skip(by: 30) } label: {
                Image(systemName: "goforward.30")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
    }
}

struct ShowNotesView: View {
    let episode: Episode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let notes = episode.summary.htmlAsPlainText
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(episode.title)
                        .font(.title3.bold())
                    if notes.isEmpty {
                        Text("This episode has no show notes.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(notes)
                            .textSelection(.enabled)
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
