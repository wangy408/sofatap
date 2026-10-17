# Minimal Mac pointer sensitivity development build

This fork variant starts from upstream revision `754d22b6f671b034e876d12f7c4ee980749a13d8`. Its only product addition is a Mac receiver mouse movement multiplier. It is software sensitivity, not hardware DPI. It does not include the earlier control-center/profile expansion.

The Mac window retains the original layout and adds a sensitivity slider. The default 1× multiplier preserves the original mouse movement speed. The preference stays on this Mac. Phone apps, phone protocol, pairing credentials and TLS behavior are unchanged. Use the complete `.app` in this package: its native Mac window and bundled receiver helper are built together from the same source revision. Do not mix binaries from different builds.

## Artifact and verification

The `Mac minimal pointer sensitivity cloud build` workflow runs on GitHub's macOS runner; it does not use or modify the user's Mac. It runs the original host regression suite, the focused sensitivity checks in that suite, the original TLS/WebSocket dry-run integration tests, and Mac launch/login/protocol/pipe tests, then compiles the complete native receiver and bundled .NET helper. The unchanged upstream build script assembles licenses and signs nested code and the app with an ad-hoc signature.

The artifact `sofatap-macos-arm64-minimal-sensitivity` contains:

- `SofaTap-macOS-arm64-minimal-sensitivity.dmg` and its SHA-256 checksum.
- `BUILD-MANIFEST.json`, identifying the exact source revision and both executable hashes.
- Development-build warnings and this document.

The DMG is created with a fixed 512 MB image capacity, compressed, and verified with `hdiutil verify`. Signature and executable hash checks precede packaging. MIT and third-party licenses are included in the app and disk image.

## Limits and installation caution

This is an Apple Silicon, macOS 15+ development build. It is ad-hoc signed, not Developer ID signed or Apple notarized. CI does not establish Gatekeeper acceptance or physical-device compatibility. No real iPhone/iPad TestFlight connection, pointer injection, or macOS Accessibility/TCC permission flow has been tested by this packaging workflow. A passing build cannot guarantee that macOS will allow the application to open.

The original application name, bundle identifier, pairing storage and permission requirements are retained. Preserve the installed copy before replacing it, quit the existing receiver first, and use the complete new app rather than replacing individual executables. Existing pairing data may be reused, but code-signature changes can require Accessibility permission to be granted again through normal macOS controls. Do not run two receiver versions together. This package does not alter or bypass Gatekeeper, TCC or any system security settings.
