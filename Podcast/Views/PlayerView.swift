import SwiftUI

struct PlayerView: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss

    private let rates: [Float] = [0.8, 1, 1.2, 1.5, 1.75, 2]

    /// Muted-spot markers and the transcript (in place of the artwork). Off each time the player
    /// opens; toggled by tapping the muted-words count.
    @State private var showsMuteDetails = false

    var body: some View {
        VStack(spacing: 24) {
            Capsule().fill(.tertiary).frame(width: 40, height: 5).padding(.top, 8)

            if let episode = player.episode {
                Spacer(minLength: 0)
                if showsMuteDetails && episode.requiresFiltering {
                    TranscriptView(
                        lines: player.transcriptLines,
                        currentTime: player.currentTime,
                        playableLimit: player.playableLimit,
                        isFullyScanned: player.isFullyScanned,
                        onSeek: player.seek(to:)
                    )
                    .frame(maxWidth: .infinity, maxHeight: 340)
                    .transition(.opacity)
                } else {
                    ArtworkView(urlString: episode.artworkURL, size: 280, cornerRadius: 20)
                        .shadow(radius: 12, y: 6)
                        .transition(.opacity)
                }

                VStack(spacing: 6) {
                    Text(episode.title)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    Text(episode.show?.title ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                ScrubberView(
                    currentTime: player.currentTime,
                    duration: player.duration,
                    playableLimit: player.playableLimit,
                    isFullyScanned: player.isFullyScanned,
                    muteMarkers: showsMuteDetails ? player.mutedRanges : [],
                    onSeek: player.seek(to:)
                )
                .padding(.horizontal, 24)

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

                HStack {
                    Menu {
                        ForEach(rates, id: \.self) { rate in
                            Button(rateLabel(rate)) { player.rate = rate }
                        }
                    } label: {
                        Label(rateLabel(player.rate), systemImage: "speedometer")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                            .background(.tint.opacity(0.12), in: .capsule)
                    }
                    .accessibilityLabel("Playback speed")
                    .accessibilityValue(rateLabel(player.rate))
                    Spacer(minLength: 12)
                    if episode.requiresFiltering {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { showsMuteDetails.toggle() }
                        } label: {
                            Label(
                                player.mutedSpotCount == 1 ? "1 filtered section" : "\(player.mutedSpotCount) filtered sections",
                                systemImage: showsMuteDetails ? "speaker.slash.fill" : "speaker.slash"
                            )
                            .font(.subheadline)
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                            .background(.tint.opacity(showsMuteDetails ? 0.22 : 0.12), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(showsMuteDetails ? "Shows the artwork again" : "Shows the transcript and sections skipped on the timeline")
                    } else {
                        Label("Filtering off", systemImage: "speaker.wave.2")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 28)

                if !player.upNext.isEmpty {
                    Label("\(player.upNext.count) up next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "play.slash")
            }
        }
        .presentationDragIndicator(.hidden)
        .onChange(of: player.episode?.id) { showsMuteDetails = false }
    }

    private func rateLabel(_ rate: Float) -> String {
        rate == 1 ? "1×" : String(format: "%g×", rate)
    }
}

struct MiniPlayerView: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(urlString: player.episode?.artworkURL, size: 32, cornerRadius: 6)
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
