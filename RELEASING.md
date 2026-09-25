# Releasing

Notes for cutting signed builds. You don't need any of this to build from source.

## How releases work

Everything lives in this repo. Releases hold the DMGs, and GitHub Pages serves the Sparkle feed the app checks:

```text
https://legendaryspy.github.io/backpocket/appcast.xml
```

1. As you work, add a line for each user-facing change under `## Unreleased` in [CHANGELOG.md](CHANGELOG.md).
2. Run the `Release` workflow with the new version, like `1.0.4`. It stops right away if the changelog has nothing for it.
3. It builds, signs, notarizes, and packages `Backpocket.dmg`, stamps the changelog section with the version and date, tags `v1.0.4`, and publishes the GitHub release with those notes.
4. Then it runs `Update Site`, which signs a new appcast for that release and publishes it to Pages along with the privacy, terms, and Sparkle license pages. Sparkle sees the update from here.

Pull after a release, since the workflow pushes the changelog commit and tag to `main`.

If you fix up the notes afterwards, edit the version's section in CHANGELOG.md and run `Update Site` by hand. Editing `Backpocket/Legal` on `main` republishes the site automatically.

Don't rename `release.yml`. Its run number becomes the build number, and Sparkle only offers updates with a higher one.

### The old feed

Builds up to 1.0.3 check `legendaryspy.github.io/backpocket-updates/appcast.xml`. The `legacy-feed` job in `site.yml` copies each new appcast there, so those installs update onto this repo's feed. Once nobody is left on 1.0.3, delete that job and the `UPDATES_REPO_TOKEN` secret, and archive `LegendarySpy/backpocket-updates`.

## Secrets

- `MACOS_CERTIFICATE_BASE64`: Developer ID Application `.p12`, base64 encoded
- `MACOS_CERTIFICATE_PASSWORD`: password for the `.p12`
- `MACOS_PROVISIONING_PROFILE_BASE64`: Developer ID provisioning profile for `com.backpocket.mac` with iCloud enabled, base64 encoded
- `KEYCHAIN_PASSWORD`: temporary CI keychain password
- `APPLE_ID`: Apple ID used for notarization
- `APPLE_APP_SPECIFIC_PASSWORD`: app-specific password for notarization
- `APPLE_TEAM_ID`: Apple developer team ID
- `SPARKLE_PRIVATE_KEY`: exported Sparkle private key, used to sign the appcast
- `UPDATES_REPO_TOKEN`: only for the old feed, see above

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

The privacy policy and terms are bundled in `Backpocket/Legal` so the About tab can show them offline. `Update Site` publishes the same files to Pages. If you change one, update its effective date.
