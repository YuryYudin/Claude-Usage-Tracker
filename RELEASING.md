# Fork release process

Publish releases to **YuryYudin/Claude-Usage-Tracker**. The inherited upstream
signing, appcast and Homebrew jobs are restricted to the upstream repository;
they require its credentials and are separate from this fork's release flow.
The fork's in-app upstream updater stays disabled.

## Prepare and validate

1. Update the app and widget `MARKETING_VERSION` together and increment their
   `CURRENT_PROJECT_VERSION`. Keep the bundle identifier to preserve account data.
2. Update README, CHANGELOG, RELEASE_NOTES and the included upgrade notes. Keep
   signing and privacy claims consistent with the actual artifacts.
3. Run the hosted test suite with the shared scheme's test-mode isolation, plus
   `python3 scripts/validate_localizations.py` and `git diff --check`.
4. Build the universal Release app under an ignored `.noindex` directory:

```sh
xcodebuild -project 'Claude Usage.xcodeproj' -scheme 'Claude Usage' \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/release.noindex ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
```

## Package

The current distribution uses the same ad-hoc signing as the tested local
installation. It is not Developer ID signed or notarized. A future signing
change requires separate credential continuity and notarization verification.

```sh
python3 scripts/package_dmg.py \
  'build/release.noindex/Build/Products/Release/Claude Usage.app' \
  release/Claude-Usage-3.4.0.dmg --ad-hoc \
  --notes docs/reviews/local-upgrade-notes.txt
```

The packager signs nested code before the app, verifies signatures and matching
app/widget metadata, checks the disabled update gate, and verifies the image.

Mount the DMG read-only below a private `.noindex` directory. Create
`Claude-Usage.zip` from its signed app using `ditto -c -k --sequesterRsrc
--keepParent`, then unmount it. Include the upgrade notes alongside the app in
the ZIP. Generate `SHA256SUMS` for the DMG and ZIP. Inspect the archives for
version/build, arm64 and x86_64 architectures, widget embedding, signatures,
absence of the automatic heartbeat endpoint and absence of production data.

## Publish

Commit release changes to main and push to the fork. Create an annotated
`v3.4.0` tag at that exact commit and push the tag to the fork. Never move an
existing published tag.

```sh
gh release create v3.4.0 --repo YuryYudin/Claude-Usage-Tracker \
  --verify-tag --draft --title 'v3.4.0 - providers, widgets and privacy' \
  --notes-file RELEASE_NOTES.md \
  release/Claude-Usage-3.4.0.dmg release/Claude-Usage.zip release/SHA256SUMS
```

Verify the draft's tag, commit, notes, assets and checksums. Publish it as the
latest release with `gh release edit v3.4.0 --draft=false --latest` using the
same explicit repository. Confirm the published release and downloadable assets.

Publishing a release does not automatically replace the working installation.
Keep previous verified installers and private recovery backups available.
