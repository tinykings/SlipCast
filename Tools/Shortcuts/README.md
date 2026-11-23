# Apple Podcasts export shortcut

`Podcast/Resources/Export Apple Podcasts.shortcut` is signed with Apple's
`shortcuts sign --mode anyone`, so it can be distributed without requiring the
recipient to know the signer. iOS still requires confirmation to install it.

The generator creates a new workflow using Apple's Get Podcasts from Library
action. It reads each item's Feed URL, XML-escapes it, writes OPML, and asks the
user where to save it. SlipCast fetches show names from the feeds during import.
No history, episode progress, network requests, or third-party services are part
of this workflow. The underlying action/property identifiers were checked against
Harold Gao's publicly shared exporter: https://haroldgao.com/post/opml/.

## Rebuild (macOS with Shortcuts)

```sh
python3 Tools/Shortcuts/build_export_shortcut.py
shortcuts sign --mode anyone \
  --input 'Tools/Shortcuts/Export Apple Podcasts.unsigned.shortcut' \
  --output 'Podcast/Resources/Export Apple Podcasts.shortcut'
```

Keep the unsigned source and signed resource together when updating the workflow.
Signing requires access to Apple's signing service; signatures are not reproducible
byte-for-byte. Review/re-sign the resource if Apple stops accepting its signature.

## iPhone acceptance test (not yet verified)

1. Follow at least two shows in Apple Podcasts.
2. In SlipCast: Settings > Import Followed Shows > Install Export Shortcut.
3. In the share sheet, open in Shortcuts. If that isn't offered, Save to Files,
   then tap the saved `.shortcut` in Files to open the installation screen.
4. Review its actions and confirm Add Shortcut. No manual action-building needed.
5. Run **Export Apple Podcasts** in Shortcuts. Grant Podcasts permission if asked.
6. Save **Apple Podcasts.opml** to Files. Return to SlipCast and choose it.
7. Confirm shows are added without immediate downloads; import again and confirm
   they are reported as already followed.
8. Also try an empty Podcasts library and denying permission. An empty export
   should be rejected by SlipCast with its no-usable-feed-URLs message.

The signature, bundle inclusion, and OPML parser can be tested on the simulator;
actual Podcasts library access and the file installation handoff require an iPhone.
