# Tethersnap

> Export Nintendo Switch 2 screenshots and videos to a Mac over USB.

macOS has no MTP support, and the Switch-1-era bridges (OpenMTP, MacDroid, Android File Transfer) fail against the Switch 2. Tethersnap is a from-scratch minimal PTP/MTP initiator over `IOUSBHost`: the console is a plain PTP 1.00 responder with no MTP vendor extension (it implements exactly the ten baseline operations 0x1001-0x100A), so Tethersnap speaks only baseline PIMA 15740, the same subset libmtp uses successfully on Linux. Validated end to end against real hardware (firmware 22.5.0): connect, enumeration, thumbnails, and byte-exact exports.

Scaffolded with [Monolith](https://github.com/Luminoid/Monolith).

## Usage

On the console: **System Settings → Data Management → Manage Screenshots and Videos → Copy to PC via USB**, connected from the console's **bottom** USB-C port (not the dock) with a full-data cable.

CLI:

```bash
swift run tethersnap probe   # device / interface / storage diagnostics
swift run tethersnap list    # list captures
swift run tethersnap pull --all --out ~/Pictures/Switch2
```

App:

```bash
make run-app             # builds .build/Tethersnap.app and opens it
```

The app reacts to console plug/unplug via IOKit notifications, shows a thumbnail grid (GetThumb when the console offers it, otherwise a bounded GetPartialObject prefix for screenshots), and supports multi-select (click / ⌘-click / shift-click ranges, ⌘A), keyboard navigation (arrows, Space/Return to preview, Escape), sorting, double-click preview with a retryable failure state, drag-out to Finder (a multi-selection drags as one folder), and per-item / selection / Export All flows with cancel. The last export folder is remembered (⌘⇧E re-exports there, or asks on first run; see Settings to inspect or clear it); summaries distinguish saved from already-existing files, capture dates are preserved as file modification dates, and the Mac won't idle-sleep mid-export. A transfer failure or cancel abandons the PTP data phase, so the app throws the session away and reconnects automatically.

The UI and error messages are localized in English and Simplified Chinese (following the system language). Strings live in classic `.lproj/Localizable.strings` files because `swift build` copies `.xcstrings` catalogs without compiling them.

## Debugging

The app writes a complete debug trace of every run to `~/Library/Logs/Tethersnap/Tethersnap.log` (the run before it is kept as `Tethersnap.previous.log`), with no setup: just reproduce the problem and grab the file, or use **Help → Reveal Log File in Finder**.

Everything also lands in the unified log under subsystem `dev.luminoid.Tethersnap` (categories `usb`, `mtp`, `library`, `app`):

```bash
/usr/bin/log stream --level debug --predicate 'subsystem == "dev.luminoid.Tethersnap"'
```

The CLI's `--verbose` flag mirrors the same messages to stderr (USB transfer hex previews, PTP transactions with response codes), which is the fastest way to see where a conversation with the console stops:

```bash
swift run tethersnap probe --verbose
```

## Targets

| Target | Kind | Notes |
|--------|------|-------|
| TethersnapKit | library | PTP containers/datasets, transaction engine, `IOUSBHost` transport, capture library |
| `tethersnap` | executable | CLI: `probe` / `list` / `pull` |
| TethersnapApp | executable | SwiftUI Mac app; bundled via `make app` |

Also recognizes the original Switch (057e:201d) alongside the Switch 2 (057e:2061).

## Development

```bash
brew bundle             # install swiftlint + swiftformat
make setup-hooks        # wire pre-commit lint + format
make build
make test               # protocol-layer tests against a scripted mock transport
make check              # strict lint + format gate
make app                # assemble .build/Tethersnap.app (release, ad-hoc signed)
make dist               # Developer ID signed + notarized DMG into dist/
```

The protocol layer is hardware-independent: `MTPSession` runs against any `MTPTransport`, and the tests script exchanges (split headers, coalesced containers, zero-length packets) through a mock.

### Releasing

`make dist` runs the whole distribution pipeline: hardened-runtime Developer ID signature, notarize the app, staple, wrap in a DMG, notarize and staple the DMG, verify with Gatekeeper. Two one-time setups, and the target prints these instructions itself when either is missing:

1. A **Developer ID Application** certificate in the keychain (create at [developer.apple.com](https://developer.apple.com/account/resources/certificates/list) or via Xcode → Settings → Accounts → Manage Certificates; requires the Account Holder role).
2. Stored notarization credentials: `xcrun notarytool store-credentials tethersnap-notary --apple-id <email> --team-id <team> --password <app-specific password>`.

The result, `dist/Tethersnap-<version>.dmg`, is what a GitHub release attaches.

## License

MIT. © Luminoid. See [LICENSE](LICENSE) and [CHANGELOG](CHANGELOG.md).

Tethersnap is an independent open-source project. It is not affiliated with, endorsed, or sponsored by Nintendo. Nintendo Switch and Nintendo Switch 2 are trademarks of Nintendo, used here only to describe compatibility.
