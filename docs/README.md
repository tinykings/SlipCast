# SlipCast website

A static, dependency-free GitHub Pages site. No build step, JavaScript, or external assets are required.

## Publish

1. Push `docs/` to the repository’s default branch.
2. In GitHub **Settings → Pages**, select **Deploy from a branch**, select that branch, and choose **/docs**.
3. Save and wait for the Pages deployment.

With the current repository name, the default URLs are:

- Website / App Store Marketing URL: `https://tinykings.github.io/SlipCast/`
- App Store Privacy Policy URL: `https://tinykings.github.io/SlipCast/#privacy`
- App Store Support URL: `https://tinykings.github.io/SlipCast/#support`

Confirm these URLs are publicly accessible after deployment before entering them in App Store Connect. If a custom domain is configured, use that domain instead.

## Preview

From the repository root:

```sh
python3 -m http.server 8000 --directory docs
```

Open `http://localhost:8000/`. Check narrow and wide layouts, light/dark appearance, keyboard navigation, and the `#privacy` link.

## Maintenance

- `index.html`: feature copy, support information, and privacy policy.
- `styles.css`: responsive layout and automatic light/dark themes.
- `assets/app-icon.png`: resized copy of the app icon.
- `.nojekyll`: serves the directory as plain static files.

No App Store listing URL was available when this page was created. Once published, add the actual listing URL to the hero rather than an App Store search link.

Review the privacy policy and effective date before release and whenever data practices change. The policy describes the current source code; it does not automatically establish the correct App Store privacy-label answers. Review those separately against Apple’s definitions, including third-party services.
