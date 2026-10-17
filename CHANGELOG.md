# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Sources beyond the Switch 2. Over USB: any still-image-class (PTP) device, which covers the original Switch, DSLR and mirrorless cameras in their PTP or MTP mode, and phones (listed, never opened on their own). From disk: mounted external drives and memory cards, with layouts for PS5 and PS4 export drives (`PS5/CREATE`, `PS4/SHARE`, grouped by game), Switch SD cards (`Nintendo/Album`, grouped by date), camera cards (`DCIM`), and a bounded walk for anything else; and any folder via File › Open Folder… (⌘O), remembered across launches (a folder on a drive that is not mounted comes back when it is).
- A sidebar listing every attached source (devices, drives, folders). The first console or camera opens on its own, a drive opens when it mounts while nothing else is open, the active source closes when it is unplugged or ejected, and Cancel on the opening screen gives up on a slow device. File-backed items get locally generated thumbnails (a frame for MP4 and MOV clips) and preview in Quick Look (videos play inline); console items keep the preview sheet.
- Fix Dates from Filenames (File menu, ⌘⇧D, toolbar button; `tethersnap fixdates`): stores the timestamp consoles, phones, and screenshot tools put in filenames (Switch and Switch 2 album names, the original Switch's USB exports, PS5 and PS4, Steam, Android, macOS screenshots) as the capture date. EXIF and XMP for JPEG, PNG, TIFF, and HEIC; the QuickTime creation date for MP4, M4V, and MOV through a passthrough re-mux; the Finder created and modified dates for every matched file. RAW, WebP, GIF, BMP, WebM, AVI, and MTS get Finder dates only. A capture date already embedded in a file (EXIF DateTimeOriginal or DateTimeDigitized, XMP CreateDate) is kept unless "Overwrite existing dates" (`--overwrite`) is chosen, while a file carrying only a TIFF modification time (the original Switch's JPEGs) gains one; `--dry-run` reports without writing and "Include subfolders" (`--no-recursive`) bounds the run. Cancel Date Fix is ⌘⌥., and an export and a date fix can run side by side with their own progress and summaries.
- `tethersnap sources`, plus `--source <index|id>` and `--folder <path>` on `probe`, `list`, and `pull`. `pull` takes `--photos-only` / `--videos-only`, accepts names exactly as `list` prints them (with the folder prefix), and finishes the run when one file fails. Ctrl-C cancels `pull` and `fixdates` cleanly (the file in progress is removed, exit code 130). `probe` prints the USB serial number.
- Exports follow the view. With Group by Folder on, Export All, a selection export, the context-menu export, and a multi-item drag write one subfolder per game or camera folder, each file under its own name (a `:` or `/` in a folder name becomes `-`); with All Items, everything goes into the chosen folder.
- A View menu (Filter, View, Sort, Preview ⌘Y), "Show in Finder" for items on a drive or folder, an Open Folder… button and one connection hint per kind of source (Switch or Switch 2, camera, PS5/PS4/Steam Deck drive) on the empty screen, and RAW photos labelled as such.
- Camera-friendly enumeration: folder names on the flat object path (so `100CANON` grouping works), a storage that reports itself unavailable (an empty card slot) or a folder the camera refuses to list is skipped instead of failing the whole listing, and a progress line every 250 objects. Clips of 4 GiB and more download (PTP reports their length as unknown).
- A "device busy" error when Image Capture, Photos, or a background helper holds the device, naming the Image Capture setting that stops it.
- Kit API: `CaptureSource`, `CaptureSourceDescriptor`, `CaptureSources`, `CaptureSourceError`, `VolumeCaptureSource`, `VolumeLayout`, `VolumeWatcher`, `FilenameDate`, `CaptureDateFixer`, `DateFixError`, `ThumbnailPayload`, `DownloadResult`, `ExportDestination` with `[CaptureItem].exportDestinations(under:groupedByFolder:)` and `CaptureItem.exportFolderName`, `TemporaryFiles`, `FileSystem`, `TethersnapVersion`, `[CaptureItem].sortedNewestFirst()`, `PTPObjectFormat.preferredExtension`, `USBMTPTransport.attachedDevices()`, `TethersnapConnection.connect(to:)`, and `abandon()` on `MTPSession`, `TethersnapConnection`, and `CaptureSource` (drop a session whose device is already gone, without a CloseSession round trip).
- The app's first log line names the app version, build, and macOS version; outcome lines for downloads (bytes written, or bytes received before a failure), exports (saved, skipped, and cancelled counts), the quit-time CloseSession timeout, thumbnail decode failures, an unavailable USB device watcher, and the app's connecting and retry transitions; and a status-bar note when the log file cannot be created, with the reason in its tooltip.
- The DMG and the repo carry `THIRD_PARTY_LICENSES.md` with the swift-argument-parser license.

### Changed

- `CaptureItem.Kind.screenshot` is now `.image`; HEIC/HEIF, WebP, GIF, BMP, TIFF, and camera RAW count as images, WebM, M4V, AVI, MTS, and M2TS as videos, and a standard PTP object format classifies files with no usable extension. `CaptureItem.id` is the item's `origin` (a PTP handle or a file URL), so `handle` and `storageID` are optional. Filename collisions across folders, not only across storages, get numbered export names, and a generated name never collides with a later original. An item whose reported filename cannot name a file (empty, `.`, `..`, a slash) is exported under a handle-based name; the export folder itself is never a destination.
- `USBMTPTransport.DeviceID` carries the USB location, serial number, and kind; `USBDeviceWatcher` reports any still-image-class device, not only the two console IDs. Removed: `USBMTPTransport.init()` and `attachedDeviceID()`, `TethersnapConnection.connect()` without an argument and `isSessionValid` (use `CaptureSources`, `connect(to:)`, and `isValid`), `CaptureLibrary.thumbnailData(for:)` and `imageDataPrefix(for:maxBytes:)` (use `thumbnailPayload`), and `TethersnapLog.disableFileLogging()`.
- The CLI's default export folder is `~/Pictures/Tethersnap` (was `~/Pictures/Switch2`), its default source is the first console or camera (a phone is listed but never picked), `list --screenshots-only` is `--photos-only` (the old flag still works), every error prints as `error:` on stderr, and progress lines are shown only on a terminal.
- App wording: "Photos" instead of "Screenshots", "Group by Folder" instead of "Group by Game", items instead of captures, and the window opens wider to fit the sidebar. Export destinations are chosen in a standard Open panel preset to the remembered folder. The Filter control (All, Photos, Videos) sits in the center of the toolbar and Export is a prominent, titled button at its trailing end; a click or a drag-to-select starts anywhere in the grid pane, not only over the rows. Closing the window quits the app and releases the device. Kit error messages say "device" instead of "console".
- Logging has six levels (`debug`, `info`, `notice`, `warning`, `error`, `fault`). Sessions, connects, enumeration, and export outcomes log at `notice`, so they are saved on disk; recoveries (stall clears, the stale-session ladder, the session-first handshake, the flat-query fallback) log at `warning` or `notice`. Errors are logged with their domain and code instead of a localized description, which on a Chinese system came out in Chinese with no code. File paths are private in the unified log.
- `--verbose` stderr lines carry a local timestamp and the category (`HH:mm:ss.SSS [level] category: message`). Log-file lines carry an ISO-8601 timestamp, level, category, and message, plus the private detail (paths), since the file stays on the user's Mac.
- Debug lines are written only while `--verbose` or the app's log file is on (or `TethersnapLog.minimumLevel` is lowered); `log stream --level debug` alone no longer shows them.
- CLI diagnostics (`error:`, `warning:`, `FAILED`) go to stderr; stdout keeps listings, progress, and summaries.
- `TethersnapLog.enableFileLogging(at:)` throws instead of returning nil, and `handler` entries carry the category as a string (`usb`, `mtp`, `library`, `volume`, `dates`, `app`), matching the unified-log predicates.

### Fixed

- A USB failure in the middle of listing captures returned the partial list as if it were complete; it now fails, and the app reconnects.
- A session failure while thumbnails were loading reconnected once per visible cell instead of once, and the export summary after a cancel or failure vanished the moment the app reconnected.
- The Edit menu carried two Select All items; the app's own ⌘A is gone and the system one selects the grid.
- Up and Down arrows in the grid moved by one item instead of one row.
- `tethersnap --version` reported 0.1.0 while the app was 0.2.0; the CLI and app now report the same version.
- `tethersnap pull` exited 0 when none of the named files were on the console; it now exits non-zero.
- The CLI's date column followed the system's 12-hour clock setting, breaking its alignment.
- A PTP date with an impossible day (February 30) was rolled into the next month instead of being ignored.
- Bulk-transfer failures logged no error code, so a timeout, a stall, and an unplug looked alike; stall clearing and descriptor reads now log their error codes.
- A failed log-file setup (folder, rotation, or file open) was silent.
- The 5-second discovery poll logged "no console" on every poll; it now logs when discovery changes.
- Bulk-pipe stall recovery matched the legacy IOUSBFamily code (0xe0004007, `kIOUSBWrongPIDErr`) instead of IOUSBHost's own `kUSBHostReturnPipeStalled` (0xe0005000), so a real STALL handshake never triggered `clearStall`. Both families are now recognized, sign-extended forms included.
- A device reporting an empty or slash-containing filename could make an export delete the export folder or write outside it; such items are now refused with an error.
- Filenames, console folder names, drive labels, and folder paths appeared in the public text of unified-log messages, where a sysdiagnose or any admin on the Mac can read them; they now travel as private detail, which the log file keeps in full.
- Unplugging the open console sent a CloseSession to the removed device, which failed and logged as an error; the session is now dropped without a round trip. Two more log-noise fixes: a macOS update's staging volume mounting and unmounting no longer logs as a drive event, and memory pressure logs only when cached thumbnails were dropped.

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
