# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-10-18

### Added

- Sources beyond the Switch 2: any still-image-class (PTP) USB device, which covers the original Switch, cameras in PTP or MTP mode, and phones (listed, never opened on their own); mounted drives and memory cards, with layouts for PS5 and PS4 export drives (grouped by game), Switch SD cards (grouped by date), and camera cards (`DCIM`, plus Sony's `PRIVATE/M4ROOT/CLIP` and AVCHD `STREAM` clip folders); and any folder via File › Open Folder… (⌘O), remembered across launches.
- A sidebar of attached sources. The first console or camera opens on its own, a drive opens when it mounts while nothing is open, and the active source closes when it is unplugged or ejected. File-backed items get local thumbnails and Quick Look previews.
- Fix Dates from Filenames (⌘⇧D, toolbar button, `tethersnap fixdates`): stores the timestamp in console, phone, and screenshot filenames as the capture date, in EXIF and XMP for JPEG, PNG, TIFF, and HEIC, in the QuickTime creation date for MP4, M4V, and MOV (patched in place, no re-mux), and in the Finder dates of every matched file; RAW, WebP, GIF, BMP, WebM, AVI, MTS, and M2TS get Finder dates only. An embedded date is kept unless "Overwrite existing dates" (`--overwrite`) is on. A Sony clip's record (`C0001M01.XML`) supplies the exact time with its zone, the camera make and model, and the position, embedded as the keys Photos reads ("Use the camera's clip record", `--no-clip-metadata`). Also `--dry-run`, "Include subfolders" (`--no-recursive`), and Cancel Date Fix (⌘⌥.).
- CLI: `tethersnap sources`, `--source <index|id>` and `--folder <path>` on `probe`, `list`, and `pull`; `pull --photos-only` / `--videos-only`, names as `list` prints them, and a run that continues past a failed file; Ctrl-C cancels cleanly (exit code 130); `probe` prints the USB serial number.
- Exports follow the view: Group by Folder writes one subfolder per game or camera folder (Export All, selection, context menu, and multi-item drags), All Items writes a flat folder.
- A View menu (Filter, View, Sort, Preview ⌘Y), Show in Finder for file-backed items, one connection hint per source kind on the empty screen, and RAW photos labelled as such.
- Camera-friendly enumeration: folder names on the flat object path, unavailable storages and unlistable folders skipped instead of failing the listing, and clips of 4 GiB and more.
- A "device busy" error when Image Capture, Photos, or a background helper holds the device, naming the setting that stops it.
- Kit API: `CaptureSource`, `CaptureSourceDescriptor`, `CaptureSources`, `CaptureSourceError`, `VolumeCaptureSource`, `VolumeLayout`, `VolumeWatcher`, `FilenameDate`, `CaptureDateFixer`, `SonyClipMetadata`, `DateFixError`, `ThumbnailPayload`, `DownloadResult`, `ExportDestination`, `TemporaryFiles`, `FileSystem`, `TethersnapVersion`, `[CaptureItem].sortedNewestFirst()`, `PTPObjectFormat.preferredExtension`, `USBMTPTransport.attachedDevices()`, `TethersnapConnection.connect(to:)`, and `abandon()` on sessions, connections, and sources.
- Logging: the first line names the app version, build, and macOS version; outcome lines for downloads, exports, and the quit-time CloseSession timeout; a status-bar note when the log file cannot be created.
- `THIRD_PARTY_LICENSES.md` in the DMG and the repo.

### Changed

- `CaptureItem.Kind.screenshot` is `.image`, more image and video extensions count as media, a standard PTP object format classifies files with no usable extension, and `CaptureItem.id` is the item's `origin`, so `handle` and `storageID` are optional. Filename collisions across folders get numbered names in a flat export; a filename that cannot name a file is exported under a handle-based name.
- `USBMTPTransport.DeviceID` carries the USB location, serial number, and kind; `USBDeviceWatcher` reports any still-image-class device. Removed: `USBMTPTransport.init()` and `attachedDeviceID()`, `TethersnapConnection.connect()` and `isSessionValid`, `CaptureLibrary.thumbnailData(for:)` and `imageDataPrefix(for:maxBytes:)`, and `TethersnapLog.disableFileLogging()`.
- CLI: the default export folder is `~/Pictures/Tethersnap` (was `~/Pictures/Switch2`), the default source is the first console or camera, `list --screenshots-only` is `--photos-only` (the old flag still works), errors print as `error:` on stderr, and progress lines show only on a terminal.
- App wording: "Photos" for "Screenshots", "Group by Folder" for "Group by Game", items for captures. Export destinations are chosen in a standard Open panel, the Filter control is centered in the toolbar with Export as a prominent button, and closing the window quits the app.
- Logging: six levels (`debug` to `fault`); sessions, connects, enumeration, and export outcomes at `notice`; errors carry their domain and code instead of a localized description; file paths, filenames, and folder names are private in the unified log and kept in full in the log file; `--verbose` lines carry a timestamp and category; debug lines are written only while `--verbose` or the log file is on; `TethersnapLog.enableFileLogging(at:)` throws, and `handler` entries carry the category as a string.

### Fixed

- The app crashed at launch on every Mac except the one that built it: its resource bundles were looked up at the app's root and at the build machine's path, never in `Contents/Resources`, where they ship (#1).
- Bulk-pipe stall recovery matched a legacy IOUSBFamily code, so a real STALL never triggered `clearStall`; IOUSBHost's own code is recognized, sign-extended forms included.
- A USB failure in the middle of listing captures returned the partial list as complete; it now fails, and the app reconnects.
- A session failure while thumbnails loaded reconnected once per visible cell, and the export summary after a cancel or failure vanished on reconnect.
- A device reporting an empty or slash-containing filename could make an export delete the export folder or write outside it; such items are refused.
- Unplugging the open console sent a CloseSession to the removed device, which failed and logged as an error.
- Filenames, console folder names, drive labels, and folder paths appeared in the public text of unified-log messages.
- The Edit menu carried two Select All items, and Up and Down in the grid moved by one item instead of one row.
- `tethersnap --version` reported 0.1.0, `pull` exited 0 when none of the named files existed, and the date column followed the 12-hour clock setting and broke its alignment.
- A PTP date with an impossible day (February 30) rolled into the next month instead of being ignored.
- Bulk-transfer failures logged no error code, a failed log-file setup was silent, and the discovery poll logged "no console" every 5 seconds.

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
