# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Logging is rebuilt on a shared core with six levels (`debug`, `info`, `notice`, `warning`, `error`, `fault`). Sessions, connects, enumeration, and export outcomes log at `notice`, so they are saved on disk; recoveries (stall clears, the stale-session ladder, the session-first handshake, the flat-query fallback) log at `warning` or `notice`. Errors are logged with their domain and code instead of a localized description, which on a Chinese system came out in Chinese with no code. File paths are private in the unified log.
- `--verbose` stderr lines carry a local timestamp and the category (`HH:mm:ss.SSS [level] category: message`). Log-file lines carry an ISO-8601 timestamp, level, category, and message, plus the private detail (paths), since the file stays on the user's Mac.
- Debug lines are written only while `--verbose` or the app's log file is on (or `TethersnapLog.minimumLevel` is lowered); `log stream --level debug` alone no longer shows them.
- CLI diagnostics (`error:`, `warning:`, `FAILED`) go to stderr; stdout keeps listings, progress, and summaries.
- `TethersnapLog.enableFileLogging(at:)` throws instead of returning nil, and log categories are `TethersnapLog.Category` values (`.usb`, `.mtp`, `.library`, `.app`).

### Added

- The app's first log line names the app version, build, and macOS version.
- Outcome lines for downloads (bytes written, or bytes received before a failure), exports (saved, skipped, and cancelled counts), the quit-time CloseSession timeout, thumbnail decode failures, an unavailable USB device watcher, and the app's connecting and retry transitions.
- A status-bar note when the log file cannot be created, with the reason in its tooltip.

### Fixed

- `tethersnap --version` reported 0.1.0 while the app was 0.2.0. A single `TethersnapVersion` constant now feeds the CLI, and a test keeps it equal to `Support/Info.plist`.
- `tethersnap pull` exited 0 when none of the named files were on the console; it now exits non-zero.
- Bulk-transfer failures logged no error code, so a timeout, a stall, and an unplug looked alike; `clearStall` and the configuration-descriptor read swallowed their errors.
- A failed log-file setup (folder, rotation, or file open) was silent.
- The 5-second discovery poll logged "no console" on every poll; it now logs when discovery changes.
- The Localization tests looked for `.lproj` folders at the top of the resource bundle, which fails under SwiftPM's Swift Build backend (`Contents/Resources/`); they now go through `resourceURL`.
- Bulk-pipe stall recovery matched the legacy IOUSBFamily code (0xe0004007, `kIOUSBWrongPIDErr`) instead of IOUSBHost's own `kUSBHostReturnPipeStalled` (0xe0005000), so a real STALL handshake never triggered `clearStall`. Both families are now recognized, sign-extended forms included, with a unit test.

## [0.2.0] - 2026-09-01

### Added

- Status chip at the bottom-trailing corner of every screen, stating the current connection state (e.g. "No console detected on USB").

### Changed

- Wider grid margins.

## [0.1.0] - 2026-09-01

### Fixed

- First real-hardware bug (2026-08-30): the USB interface-descriptor walk restarted from the beginning once the iterator was exhausted, spinning forever against the real console's configuration; the app froze on "Connecting…" and, because quit awaited the wedged device actor, became un-quittable. Descriptor walks now advance at the end and exit on nil, and app termination does a bounded off-main disconnect instead of `.terminateLater`.
- Real-hardware quirk (2026-08-30, firmware 22.5.0): on re-entry into transfer mode the console rejects the spec's sessionless GetDeviceInfo (empty data phase + InvalidTransactionID). The connect handshake now falls back to opening the session first and fetching DeviceInfo inside it.
- Stale-session recovery (2026-08-30): a console left with an open session by another host process (Android File Transfer Agent was the culprit in the field; a killed CLI run does it too) rejected every reconnect forever, since SessionAlreadyOpen was "tolerated" but the stale session's unknown transaction counter made all further requests InvalidTransactionID. `MTPSession.open()` now closes the stale session, falls back to the PTP class Device Reset when the close is rejected, and, because the real console STALLs that class request too, escalates to a USB device reset (software replug) with an automatic reconnect once the console re-enumerates. A fresh USB arrival now also clears a stuck failure screen.
- Hardware-validated (2026-08-30): connect, enumeration (70 captures via the recursive Album walk; the console rejects the flat query), 70 GetThumb thumbnails, and export (a screenshot and a 34.8 MB video, both byte-exact) all succeeded against firmware 22.5.0. Test fixtures now mirror the real DeviceInfo/StorageInfo profile (PTP 1.00, GetThumb yes, GetPartialObject no, all-FF capacities), and `probe` prints unreported capacities as "unknown" instead of exabytes. Storage IDs turned out to be session-dependent (0x000F0001 one session, 0x00140001 the next), so nothing persists them.

### Added

- `make dist`: full distribution pipeline (hardened-runtime Developer ID signature, app notarization + staple, DMG build, DMG notarization + staple, Gatekeeper verification), with preflight checks that explain the one-time certificate and notarytool-credential setup.
- App: rubber-band selection (drag from empty grid space to select the rectangle of captures it crosses; ⇧/⌘ add to the existing selection, a plain drag replaces it).
- App: view modes: one flat grid, or grouped by game (the console keeps one album folder per game; sections use the console's folder names with pinned headers, and `CaptureItem` now records each capture's folder from the recursive walk).
- Full-codebase audit sweep (2026-08-29), app: app icon and About copyright, Settings scene for the remembered export folder, empty states (no captures vs. no filter matches), keyboard navigation (arrows, Space/Return preview, Escape), shift-click range selection, hover highlight, retryable preview failure state, dismissible export summary that no longer covers the last grid row, Cancel Export (⌘.) and Show Export Folder menu items, first-run ⌘⇧E opens the folder picker, single-window scene, Edit menu preserved (commands added after `.pasteboard` instead of replacing it), multi-selection drag-out as one folder with per-type UTTypes (PNG no longer advertised as JPEG), export summaries that count skipped files separately.
- Audit sweep, protocol: sessions self-invalidate on any transport-class failure and every consumer reconnects instead of resuming a desynchronized responder; CloseSession on app quit and on dropped connections; GetPartialObject (in the Switch 2's supported set) powers bounded thumbnail prefixes when GetThumb is absent; one malformed or rejected object no longer aborts the whole enumeration; cross-storage filename collisions export as numbered names; skip-existing compares sizes; partial files are cleaned up on every failure path; stall clearing only fires on actual pipe stalls; a failed pipe-open tears down the claimed interface; stray event containers are capped.
- Audit sweep, performance: memoized filter/sort, coalesced export progress (one latest-wins consumer instead of a task per 512 KB chunk), reusable bulk-in buffer, debug log lines only materialize when someone is listening, previews downsample off-main and cache, thumbnails blocked during an export re-fetch when it ends.
- Audit sweep, structure and tests: `PTPContainerReader` and `PTPDateParser` extracted, `Library`/`Support` folders, shared `CaptureFormat`/`TethersnapDefaults`, `TethersnapConnection` gained a mock-transport seam; new coverage for the connect ordering, session invalidation, framing floods, download failure cleanup, collisions, the thumbnail policy, and key/placeholder parity for BOTH targets' string tables.

- Localization: English + Simplified Chinese for the app UI and TethersnapKit error messages (classic `.lproj/.strings`, SwiftPM-safe; fullwidth punctuation in zh-Hans; key/placeholder parity and locale matching covered by tests).
- App: multi-select with Export Selected (click / ⌘-click / ⌘A), sort orders, double-click preview sheet, drag-out to Finder (lazy file promise), remembered export folder with ⌘⇧E, export cancel, Show in Finder, video badge, total-size subtitle.
- Robustness: IOKit arrival/removal notifications (`USBDeviceWatcher`) with a slow poll as safety net, bulk-pipe stall clearing after failed transfers, buffered-container length sanity cap, `CancelToken` cancellation with partial-file cleanup and auto-reconnect, idle-sleep prevention during export, io_service leak fix in device discovery.
- Debugging: `TethersnapLog` unified logging (subsystem `dev.luminoid.Tethersnap`; categories usb/mtp/library/app) covering claims, transfers (hex previews), PTP transactions, and app phases; CLI `--verbose` mirrors it to stderr; the app additionally writes every run's full debug trace to `~/Library/Logs/Tethersnap/Tethersnap.log` (previous run rotated beside it) with a Help-menu item to reveal it.
- Thumbnails via GetThumb when the responder supports it (videos included), falling back to full-JPEG downsampling for screenshots.

- TethersnapKit: minimal baseline PTP/MTP initiator over IOUSBHost (container engine, DeviceInfo/StorageInfo/ObjectInfo datasets, streaming GetObject, Switch 2 + Switch 1 discovery), with a mock-transport test suite.
- `tethersnap` CLI: `probe` (diagnostics), `list`, `pull` (single/all, `--skip-existing`, capture dates preserved).
- TethersnapApp: SwiftUI Mac app with auto-connect polling, thumbnail grid, screenshot/video filter, per-item and Export All flows; `make app` assembles `.build/Tethersnap.app`.
