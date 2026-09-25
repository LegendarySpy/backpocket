# Releasing

Notes for cutting signed builds. You don't need any of this to build from source.

## How releases work

Update artifacts live in a separate public repo, [LegendarySpy/backpocket-updates](https://github.com/LegendarySpy/backpocket-updates). GitHub Pages serves it from the `gh-pages` branch, and the app checks:

```text
https://legendaryspy.github.io/backpocket-updates/appcast.xml
```

1. Run the `Release` workflow in this repo with a version number. It builds, signs, notarizes, packages `Backpocket.dmg`, and attaches it to a draft release in the updates repo. It also copies the bundled privacy, terms, and Sparkle license pages over to the updates site.
2. Edit the draft release body. That's the changelog.
3. Publish it. The updates repo rebuilds `appcast.xml` from the latest published release whenever a release is published, edited, deleted, or unpublished. Sparkle doesn't see anything until then.

## Secrets

This repo:

- `MACOS_CERTIFICATE_BASE64`: Developer ID Application `.p12`, base64 encoded
- `MACOS_CERTIFICATE_PASSWORD`: password for the `.p12`
- `MACOS_PROVISIONING_PROFILE_BASE64`: Developer ID provisioning profile for `com.backpocket.mac` with iCloud enabled, base64 encoded
- `KEYCHAIN_PASSWORD`: temporary CI keychain password
- `APPLE_ID`: Apple ID used for notarization
- `APPLE_APP_SPECIFIC_PASSWORD`: app-specific password for notarization
- `APPLE_TEAM_ID`: Apple developer team ID
- `UPDATES_REPO_TOKEN`: token that can write to `LegendarySpy/backpocket-updates`

The updates repo:

- `SPARKLE_PRIVATE_KEY`: exported Sparkle private key

Export the Sparkle key with:

```sh
.build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private_key.txt
```

Never commit it. The key files are in `.gitignore`.

## Licensing

License keys are validated against Polar's public customer portal endpoints. The build settings that configure it:

- `BACKPOCKET_POLAR_ORGANIZATION_ID`: Polar organization UUID
- `BACKPOCKET_POLAR_LICENSE_BENEFIT_ID`: license key benefit UUID
- `BACKPOCKET_POLAR_CHECKOUT_URL`: public checkout URL
- `BACKPOCKET_POLAR_PORTAL_URL`: hosted customer portal URL
- `BACKPOCKET_POLAR_API_BASE_URL`: defaults to `https://api.polar.sh/v1`

The benefit issues keys with the `BP` prefix, no expiry, and 3 active devices, with customer admin on so people can free up old Macs themselves.

Without a license the app keeps 5 facts. A valid license unlocks unlimited. If a license gets removed, extra facts stay saved locally, but only the first 5 show up in the palette until it's restored.

The key is stored in the Keychain. `UserDefaults` only holds activation and cache metadata. The app rechecks with Polar once the cached check is more than 24 hours old. A license that validated before keeps working through network or Polar outages, and only an explicit revoked, disabled, expired, or invalid response takes it away.

## Icons

`Icon/icon.icon` is the app icon, and Xcode compiles it directly. The SVG layers are also in `Icon/AppIcon-Layers`. `Icon/tray.png` is the menu bar source. Rebuild the template image set with ImageMagick:

```sh
./scripts/build_icons.sh
```

## Privacy and terms

The privacy policy and terms are bundled in `Backpocket/Legal` so the About tab can show them offline. The Release workflow publishes the same files to the updates site. If you change one, update its effective date.
