# Backpocket

A tiny Mac menu bar app for the stuff you keep retyping.

Double-tap ⌥ Option in any text field and a little Liquid Glass palette pops up right at your cursor. Type a few letters, hit Return, and the value lands in the field you were already in. Email, address, phone number, IBAN, passport number, whatever.

**[Download Backpocket](https://github.com/LegendarySpy/backpocket/releases/latest/download/Backpocket.dmg)** · [Changelog](CHANGELOG.md) · [Report a bug](https://github.com/LegendarySpy/backpocket/issues)

Needs macOS 26 Tahoe or later.

## Why I made it

I got tired of retyping the same few things every day. Text expanders sort of do this, but you have to remember an abbreviation for everything, and your passport number ends up sitting in a plain text snippet. Password managers are built for logins, not for "what's my IBAN again." So I made the small thing in between.

## What it does

- Opens at your caret, above or below the text box depending on where there's room. It also works in Chrome, Electron apps, and terminals, which took a lot of fiddling.
- Reads the label on the field you're in, so in an email box your email is already selected
- Fuzzy search over names and values. If nothing matches, Return just types what you wrote.
- Shows a preview of exactly what Return will type
- Locked facts get encrypted with AES-GCM before they're saved or synced. They're masked in the palette, need Touch ID to insert, and never touch the clipboard.
- Placeholders like `{date}`, `{time}`, `{clipboard}`, `{uuid}`, `{app}`, or `{date:+7:MMM d}` for a week from today
- Quick capture: select text anywhere, right-click, Services, Save to Backpocket
- iCloud sync between your Macs, plus JSON export and import
- You can pick the trigger key: Option, Control, Command, or Shift

## How it inserts text

Normal facts get pasted: Backpocket puts the value on the pasteboard, marks it transient so clipboard managers skip it, presses ⌘V, and then puts back whatever you had copied before. Pasting is one keystroke, so nothing gets dropped halfway through a long value.

Locked facts never go on the pasteboard at all. Backpocket writes them straight into the field through Accessibility when it can confirm that worked, and otherwise types them out one key at a time using your actual keyboard layout.

## Privacy

The only permission is Accessibility. It needs that to find your cursor and type for you.

There are no analytics, no ads, and no crash reporting. The app only goes online to check for updates (Sparkle), check your license if you have one (Polar), and sync through iCloud if you leave that on. Nothing gets sent to me. Your facts only go to your own iCloud, and locked ones are encrypted before they get there.

## Price

The code is AGPL-3.0, so you can build it yourself and change whatever you want. If you share a modified version, it has to stay open source under the same license.

The signed builds on the releases page let you save 5 facts for free. $5 once unlocks unlimited facts on up to three Macs. That's what pays for the Apple developer account and notarization, so if you end up using it every day, grabbing a license would be awesome.

## Building it yourself

You need Xcode 26 or later. Xcode 26 doesn't include the Metal toolchain by default, and the About tab uses a small shader, so grab that first:

```sh
xcodebuild -downloadComponent MetalToolchain
```

The project is set up to sign with my team and a Developer ID profile, so it won't sign on your machine as-is. In Xcode, go to the Backpocket target, then Signing & Capabilities:

1. Turn on "Automatically manage signing" and pick your own team
2. Change the bundle identifier to something of your own
3. Keep the iCloud key-value store and keychain group entitlements if you want sync and locked facts to work. If you just want to poke around, you can remove them.

Then hit ⌘R. `./build.sh` builds Release and installs it to /Applications, but it uses the project's signing settings, so it's really for me.

Once it's running, grant Accessibility access when it asks. If you rebuild with a different signature later, macOS might need you to toggle Backpocket off and back on in System Settings, Privacy & Security, Accessibility.

To debug where the palette opens, stream the geometry log:

```sh
log stream --predicate 'subsystem == "com.backpocket.mac"'
```

It logs anchor rects and which fallback got used. It never logs fact values.

## Where things are

| File | What it does |
| --- | --- |
| `DoubleTap.swift` | Watches for the double-tap on the modifier key |
| `CaretLocator.swift` | Finds the caret through Accessibility, with fallbacks for Chromium and terminals |
| `PaletteController.swift`, `PaletteView.swift` | The palette panel, where it goes, and inserting the value |
| `Fuzzy.swift` | Search and ranking (match quality, recency, per-app use, field label) |
| `Typer.swift`, `Pasteboard.swift` | Synthetic typing and the transient paste |
| `Vault.swift`, `Auth.swift` | Encryption for locked facts and the Touch ID gate |
| `Models.swift` | Facts, saving to disk, and iCloud sync |
| `Placeholders.swift` | `{date}` and friends |
| `LicenseManager.swift` | Polar license checks and the free fact limit |

## Contributing

Issues and PRs are welcome. If it's a big change, open an issue first so we can talk about it before you put the time in. For bugs where the palette shows up in the wrong place, tell me the app and the kind of text field, and a snippet of the geometry log helps a lot.

Release and signing notes are in [RELEASING.md](RELEASING.md).

## License

[AGPL-3.0](LICENSE). Sparkle has its own license, which is bundled in the app.
