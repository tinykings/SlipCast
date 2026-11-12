import SwiftUI

struct ArtworkView: View {
    let urlString: String?
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 8

    var body: some View {
        AsyncImage(url: urlString.flatMap(URL.init(string:))) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [.brandGradientStart, .brandGradientEnd],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "waveform")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(Color.brandGlyph)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius))
    }
}

struct ProgressRing: View {
    /// nil = indeterminate
    let fraction: Double?
    var systemImage: String = "stop.fill"
    var tint: Color = .accentColor

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: 2.5)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear, value: fraction)
            } else {
                ProgressView().controlSize(.small)
            }
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: 28, height: 28)
    }
}

enum Format {
    static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let minutes = Int(seconds / 60)
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(max(1, minutes)) min"
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(max(0, seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

extension String {
    /// Show notes are usually HTML; this is good enough for list previews.
    var strippingHTML: String {
        replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension View {
    /// Brand-style filled circle button glyph (play, pause, add): charcoal symbol on the accent
    /// fill, so it stays readable on the bright turquoise used in dark mode.
    func accentCircleSymbol() -> some View {
        symbolRenderingMode(.palette)
            .foregroundStyle(Color.onAccent, Color.accentColor)
    }

    /// Shows a tab's title on the left of the navigation bar, on the same row as its toolbar
    /// buttons, instead of a large title below them.
    func tabTitle(_ title: String) -> some View {
        modifier(TabTitle(title: title))
    }
}

private struct TabTitle: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)  // still used for back buttons and accessibility
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text(title)
                        .font(.title2.bold())
                        .fixedSize()
                        .accessibilityAddTraits(.isHeader)
                }
                .sharedBackgroundVisibility(.hidden)
            }
    }
}
