import SwiftUI

/// Shown instead of the app on devices without on-device speech transcription.
struct UnsupportedDeviceView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Device Not Supported", systemImage: "waveform.slash")
                .foregroundStyle(Color.accentColor)
        } description: {
            Text("""
                SlipCast mutes words by transcribing episodes on your iPhone, and this device \
                doesn't support Apple's on-device speech transcription.

                A newer iPhone is required.
                """)
        }
    }
}

#Preview {
    UnsupportedDeviceView()
}
