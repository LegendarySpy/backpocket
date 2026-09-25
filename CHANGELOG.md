# Changelog

Add changes under Unreleased as you make them. The Release workflow turns that section into the release notes and stamps it with the version and date.

## Unreleased

- Pasting no longer leaves macOS thinking ⌘ Command is still held down afterwards.
- ⌘V now works on keyboard layouts that switch to QWERTY while Command is held, like Dvorak - QWERTY ⌘.
- If an app ignores the paste, Backpocket now types the value out instead of doing nothing.
- Your clipboard comes back as soon as the app has pasted, and slow apps like remote desktops get more time before it does.
- Typing a locked fact no longer leaves Shift or Option stuck.
- When there's no caret or text box to anchor to, the palette opens at your mouse pointer.
- Backpocket is now open source under the AGPL-3.0, and updates come straight from the main repository.

## 1.0.3 - 2026-08-30

- Lower background activity while Backpocket is sitting in your menu bar.
- Update and license checks no longer run more often than they need to.

## 1.0.2 - 2026-08-30

- Backpocket now opens right away after the double-tap.
- Faster, more reliable placement when switching between apps.

## 1.0.1 - 2026-08-30

- A new first-run setup that makes Accessibility permission clear and easy
- New Backpocket app and menu bar icons
- Redesigned Settings and About, including built-in update controls
- Import and export backups for your saved facts
- Better handling for locked facts, iCloud sync, and the five-fact free plan
- Privacy, terms, and bug reporting are now available inside the app

## 0.3.0 - 2026-07-07

- Quick capture: select text in any app, then right-click → Services → Save to Backpocket
- The selected result now previews exactly what Return will type
- Search matches inside fact values, not just their names
- Suggestions are ranked by the focused field's label, so the right fact is usually already selected
- The palette now anchors reliably in Chrome and other Chromium apps, and opens instantly and settled
- More dependable caret anchoring, focus, and placement across apps
- A nicer installer: the download now opens as a proper drag-to-Applications window

## 0.2.0 - 2026-07-06

- Improved license management with customer portal access and safer draft-based release publishing.
