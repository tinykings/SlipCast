import SwiftUI

struct PlayerView: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss

    private let rates: [Float] = [0.8, 1, 1.2, 1.5, 1.75, 2]

    var body: some View {
        VStack(spacing: 24) {
            Capsule().fill(.tertiary).frame(width: 40, height: 5).padding(.top, 8)

            if let episode = player.episode {
                Spacer(minLength: 0)
                ArtworkView(urlString: episode.artworkURL, size: 280, cornerRadius: 20)
                    .shadow(radius: 12, y: 6)

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
                        Text(player.isDownloading ? "Downloading and scanning ahead…" : "Scanning ahead for muted words…")
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
                        Text(rateLabel(player.rate)).font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                    if !player.upNext.isEmpty {
                        Label("\(player.upNext.count) up next", systemImage: "text.line.first.and.arrowtriangle.forward")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Label(
                        player.mutedSpotCount == 1 ? "1 spot muted" : "\(player.mutedSpotCount) spots muted",
                        systemImage: "speaker.slash"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28)

                Spacer(minLength: 0)
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "play.slash")
            }
        }
        .presentationDragIndicator(.hidden)
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
/// the scanned part (it fills in quickly, since scanning runs much faster than playback).
struct ScrubberView: View {
    let currentTime: Double
    let duration: Double
    let playableLimit: Double
    let isFullyScanned: Bool
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
