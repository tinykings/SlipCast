import SwiftUI

struct ArtworkView: View {
    /// Tried in order; the next one loads if the previous is missing or fails.
    let urlStrings: [String]
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 8

    init(urlString: String?, size: CGFloat = 56, cornerRadius: CGFloat = 8) {
        self.init(urlStrings: [urlString], size: size, cornerRadius: cornerRadius)
    }

    init(urlStrings: [String?], size: CGFloat = 56, cornerRadius: CGFloat = 8) {
        var seen = Set<String>()
        self.urlStrings = urlStrings.compactMap { $0 }.filter { !$0.isEmpty && seen.insert($0).inserted }
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        CachedArtwork(urls: urlStrings.compactMap(URL.init(string:)), size: size) { placeholder }
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: cornerRadius))
    }

    private var placeholder: some View {
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

/// Loads the first candidate that succeeds through `ArtworkCache`, so art persists across launches.
private struct CachedArtwork<Placeholder: View>: View {
    let urls: [URL]
    let size: CGFloat
    @ViewBuilder let placeholder: () -> Placeholder

    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (urls: [URL], image: UIImage)?

    private var pixelSize: Int { max(1, Int((size * displayScale).rounded(.up))) }

    /// Memory hit for the current URLs, so cached art shows on the first frame without a flash.
    private var image: UIImage? {
        if let loaded, loaded.urls == urls { return loaded.image }
        for url in urls {
            if let image = ArtworkCache.shared.cachedImage(for: url, pixelSize: pixelSize) { return image }
        }
        return nil
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: TaskKey(urls: urls, pixelSize: pixelSize)) {
            if image != nil { return }
            for url in urls {
                if let image = await ArtworkCache.shared.image(for: url, pixelSize: pixelSize) {
                    loaded = (urls, image)
                    return
                }
                if Task.isCancelled { return }
            }
        }
    }

    private struct TaskKey: Equatable {
        let urls: [URL]
        let pixelSize: Int
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

/// Show notes as styled text with tappable links.
enum ShowNotes {
    /// Runs the HTML importer, which uses WebKit, so it must run on the main thread.
    static func attributed(_ notes: String) -> AttributedString {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AttributedString() }
        let text = importHTML(trimmed) ?? NSMutableAttributedString(string: decodeEntities(trimmed))
        tidy(text)
        linkBareURLs(in: text)
        return convert(text)
    }

    private static func importHTML(_ html: String) -> NSMutableAttributedString? {
        let caseless: String.CompareOptions = [.regularExpression, .caseInsensitive]
        guard html.range(of: "<[a-z/][^>]*>", options: caseless) != nil else { return nil }
        let prepared = html
            // The importer fetches images synchronously, and they'd show as blank boxes anyway.
            .replacingOccurrences(of: "<(img|iframe|video|audio|source)\\b[^>]*>", with: "", options: caseless)
            // Paragraph spacing is a paragraph style, which SwiftUI text ignores; use a blank line.
            .replacingOccurrences(of: "</(p|h[1-6]|ul|ol)>", with: "$0<br>", options: caseless)
        guard let data = ("<meta charset=\"utf-8\">" + prepared).data(using: .utf8) else { return nil }
        return try? NSMutableAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        )
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func tidy(_ text: NSMutableAttributedString) {
        let string = text.mutableString
        func replace(_ pattern: String, with template: String) {
            string.replaceOccurrences(of: pattern, with: template, options: .regularExpression,
                                      range: NSRange(location: 0, length: string.length))
        }
        replace("[\u{2028}\u{2029}]", with: "\n")
        replace("\u{00A0}", with: " ")
        replace("\t*([•◦▪]|\\d+\\.)\t", with: "$1 ")  // list markers come out as "\t•\t"
        replace("[ \t]+\n", with: "\n")
        replace("\n{3,}", with: "\n\n")
        let whitespace = CharacterSet.whitespacesAndNewlines
        while let last = string.length > 0 ? UnicodeScalar(string.character(at: string.length - 1)) : nil,
              whitespace.contains(last) {
            text.deleteCharacters(in: NSRange(location: string.length - 1, length: 1))
        }
        while let first = string.length > 0 ? UnicodeScalar(string.character(at: 0)) : nil,
              whitespace.contains(first) {
            text.deleteCharacters(in: NSRange(location: 0, length: 1))
        }
    }

    /// Plain-text notes often paste URLs without a link around them.
    private static func linkBareURLs(in text: NSMutableAttributedString) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let range = NSRange(location: 0, length: text.length)
        for match in detector.matches(in: text.string, range: range) {
            guard let url = match.url,
                  text.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { continue }
            text.addAttribute(.link, value: url, range: match.range)
        }
    }

    private static func convert(_ text: NSAttributedString) -> AttributedString {
        let string = text.string as NSString
        var result = AttributedString()
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var run = AttributedString(string.substring(with: range))
            if let url = link(attributes[.link]) { run.link = url }
            if let font = attributes[.font] as? UIFont {
                let traits = font.fontDescriptor.symbolicTraits
                var intent: InlinePresentationIntent = []
                if traits.contains(.traitBold) { intent.insert(.stronglyEmphasized) }
                if traits.contains(.traitItalic) { intent.insert(.emphasized) }
                if !intent.isEmpty { run.inlinePresentationIntent = intent }
            }
            result += run
        }
        return result
    }

    /// Links without a scheme ("www.example.com") can't be opened, so assume https.
    private static func link(_ value: Any?) -> URL? {
        let url = (value as? URL) ?? (value as? String).flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
        guard let url else { return nil }
        if url.scheme != nil { return url }
        return URL(string: "https://" + url.absoluteString)
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
    /// - Parameter detail: smaller secondary text after the title, e.g. storage used.
    func tabTitle(_ title: String, detail: String? = nil) -> some View {
        modifier(TabTitle(title: title, detail: detail))
    }
}

private struct TabTitle: ViewModifier {
    let title: String
    let detail: String?

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)  // still used for back buttons and accessibility
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        if let detail {
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .fixedSize()
                }
                .sharedBackgroundVisibility(.hidden)
            }
    }
}
