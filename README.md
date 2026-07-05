# Backpocket

Your facts, one double-tap away.

Backpocket is a tiny macOS menu bar utility. Double-tap ⌥ Option in any text field and a small Liquid Glass palette appears at your caret. Type a few letters to fuzzy-search your personal facts (email, IBAN, addresses, whatever you retype constantly), press Return, and the value is typed into the field you were in. The clipboard is never touched.

## Highlights

- Caret-anchored palette that opens above or below your text box, wherever there's room
- Fuzzy search with matched-letter highlighting; no match means Return types your query as-is
- Keystroke insertion via synthetic typing, so values never enter the clipboard
- One permission: Accessibility (to find your caret and type for you)
- Configurable trigger (double-tap ⌥ ⌃ ⌘ or ⇧), launch at login, native tabbed Settings

## Building

Open `Backpocket.xcodeproj` in Xcode 26+ and run, or:

```sh
./build.sh
```

which builds Release and installs to /Applications.

Requires macOS 26 (Tahoe).
