# SlipCast

A podcast player for iPhone with custom word filtering, on-device transcription, and offline listening.

## Features

- **Custom word filtering:** Choose words and phrases to skip, enable filtering per show, and adjust padding around matches.
- **Read-along transcripts:** Follow publisher-provided transcripts or generate them on a supported device. Tap the transcript to jump to a moment in an episode.
- **Podcast discovery:** Search Apple’s podcast directory, browse charts, or subscribe using an RSS feed URL.
- **Offline listening:** Download episodes, automatically fetch new releases, limit automatic downloads to Wi-Fi, and optionally delete played downloads.
- **Playback controls:** Adjust speed, build an Up Next queue, set a sleep timer, navigate available chapters, and jump between detected music sections.
- **iCloud sync:** Keep subscriptions, played history, playback positions, muted words, and supported settings in sync across your devices.

## Import followed shows

In SlipCast, open **Settings → Import Followed Shows** and choose a podcasts OPML file from Files. To switch from Apple Podcasts, use [Harold Gao’s export shortcut](https://haroldgao.com/post/opml/#2-export-your-apple-podcast-subscription-list-into-other-podcast-apps) on your iPhone to save the file first.

SlipCast skips shows you already follow. Importing leaves existing episodes undownloaded and uses your auto-download setting for upcoming releases. OPML carries feed subscriptions only.

## Requirements

- iPhone running iOS 26.1 or later.
- On-device transcription and filtering require supported Apple Speech hardware and languages.
- Filtered episodes must finish processing before playback.

Automated filtering can miss words or skip unintended audio. It is not a guarantee that an episode is free of unwanted content or suitable for children.

## Privacy

SlipCast has no developer-operated backend, advertising, or analytics SDKs. Audio analysis runs on your device. Downloads, generated transcripts, and audio scans are not synced by the app; subscriptions, listening progress, muted words, and supported settings sync through your own iCloud account.

Podcast discovery and content downloads connect directly to Apple and podcast hosting services, which handle requests under their own privacy policies.

Read the full [Privacy Policy](https://tinykings.github.io/SlipCast/#privacy).

## Build and run

1. Clone this repository and open `SlipCast.xcodeproj` in Xcode with the iOS 26.1 SDK or later.
2. Configure signing for your development team.
3. Select the SlipCast scheme and run on a compatible iPhone.

Xcode resolves the Swift package dependencies. Use a supported physical device to test transcription and filtering; Apple Speech transcription is unavailable in the simulator.

## Support

Report bugs and request features through [GitHub Issues](https://github.com/tinykings/SlipCast/issues). Include your iPhone model, iOS version, and steps to reproduce the problem. Issues are public, so do not include personal information.

[Website](https://tinykings.github.io/SlipCast/) · [Source code](https://github.com/tinykings/SlipCast)
