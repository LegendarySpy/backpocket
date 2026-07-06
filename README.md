# Backpocket

Your facts, one double-tap away.

Backpocket is a tiny macOS menu bar utility. Double-tap ⌥ Option in any text field and a small Liquid Glass palette appears at your caret. Type a few letters to fuzzy-search your personal facts (email, IBAN, addresses, whatever you retype constantly), press Return, and the value is typed into the field you were in. The clipboard is never touched.

## Highlights

- Caret-anchored palette that opens above or below your text box, wherever there's room
- Fuzzy search with matched-letter highlighting; no match means Return types your query as-is
- Keystroke insertion via synthetic typing, so values never enter the clipboard
- Dynamic placeholders in values and built-in palette results: `{date}`, `{shortdate}`, `{longdate}`, `{time}`, `{datetime}`, `{iso}`, `{timestamp}`, `{clipboard}`, `{username}`, `{fullname}`, `{hostname}`, `{app}`, `{uuid}`, or offset/formatted dates like `{date:+7:MMM d}`
- iCloud sync for your saved facts across Macs signed into the same Apple Account
- Free for up to 5 saved facts; a one-time license unlocks unlimited facts
- One permission: Accessibility (to find your caret and type for you)
- Configurable trigger (double-tap ⌥ ⌃ ⌘ or ⇧), launch at login, native tabbed Settings

## Building

Open `Backpocket.xcodeproj` in Xcode 26+ and run, or:

```sh
./build.sh
```

which builds Release and installs to /Applications.

Requires macOS 26 (Tahoe).

## Updates

Backpocket uses Sparkle for app updates. The app checks:

```text
https://legendaryspy.github.io/backpocket-updates/appcast.xml
```

Use a separate public `LegendarySpy/backpocket-updates` repository for update
artifacts so this source repository can stay private. Configure GitHub Pages on
that repository to publish from the `gh-pages` branch.

The release workflow expects these source-repo secrets:

- `MACOS_CERTIFICATE_BASE64`: Developer ID Application `.p12`, base64 encoded
- `MACOS_CERTIFICATE_PASSWORD`: password for the `.p12`
- `KEYCHAIN_PASSWORD`: temporary CI keychain password
- `APPLE_ID`: Apple ID used for notarization
- `APPLE_APP_SPECIFIC_PASSWORD`: app-specific password for notarization
- `APPLE_TEAM_ID`: Apple developer team ID
- `SPARKLE_PRIVATE_KEY`: exported Sparkle private key
- `UPDATES_REPO_TOKEN`: token that can write to `LegendarySpy/backpocket-updates`

Export the Sparkle private key for the GitHub secret with:

```sh
.build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private_key.txt
```

Do not commit the exported private key.

## Licensing

Backpocket validates Polar license keys from the app using Polar's public
Customer Portal license-key endpoints. Configure these build settings before a
paid release:

- `BACKPOCKET_POLAR_ORGANIZATION_ID`: Polar organization UUID
- `BACKPOCKET_POLAR_LICENSE_BENEFIT_ID`: Backpocket license-key benefit UUID
- `BACKPOCKET_POLAR_CHECKOUT_URL`: public Polar checkout or product URL
- `BACKPOCKET_POLAR_API_BASE_URL`: defaults to `https://api.polar.sh/v1`

Current Polar setup:

- Organization: `98d75121-191c-4136-aa56-2c7803173973` (`g-squared`)
- Product: `250c1267-b46c-4a14-affa-0822d0f85ebf` (`Backpocket`)
- License benefit: `8c725bcf-1e7f-402b-90c8-19440b7654d2` (`BackPocket`)
- Price: `$5` one-time
- Checkout: `https://buy.polar.sh/polar_cl_36BZ6cLy0UzrhGLAGQoXSNhKR9XKJE6DUFHFs0Ww7PE`

The Polar `license_keys` benefit has prefix `BP`, no expiry, and `3` active
devices with customer admin enabled so customers can free old devices.

Backpocket runs free with up to 5 saved facts. A valid license unlocks unlimited
saved facts. Extra facts are preserved locally if a license is removed, but only
the first 5 are available in the palette until the license is restored.

License keys are stored in Keychain. The app stores only activation/cache
metadata in `UserDefaults`, refreshes with Polar on launch, and allows a short
offline grace period after the last successful validation.
