import ArgumentParser
import Foundation
import TethersnapKit

@main
struct Tethersnap: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tethersnap",
        abstract: "Export photos and videos from game consoles, cameras, and drives to a Mac.",
        discussion: """
        Sources are USB PTP devices and mounted drives. A Nintendo Switch or Switch 2 needs its \
        Copy-to-PC mode: System Settings → Data Management → Manage Screenshots and Videos → \
        Copy to PC via USB, from the console's BOTTOM USB-C port with a full-data cable (not the dock). \
        A camera needs its PTP or MTP USB mode. Drives and memory cards (PS5, PS4, Switch SD, camera \
        cards, anything with photos) appear as soon as they mount. 'tethersnap sources' lists what is \
        attached; --source picks one and --folder opens any folder instead.

        Tethersnap is an independent project, not affiliated with or endorsed by Nintendo, Sony, or Valve.
        """,
        version: TethersnapVersion.current,
        subcommands: [Sources.self, Probe.self, List.self, Pull.self, FixDates.self],
        defaultSubcommand: List.self
    )
}

// MARK: - Helpers

struct GlobalOptions: ParsableArguments {
    @Flag(name: [.short, .long], help: "Mirror timestamped debug logs (USB transfers, PTP transactions) to stderr.")
    var verbose = false

    func apply() {
        TethersnapLog.echoToStderr = verbose
    }
}

/// Which source a command works on; the default is the first attached console
/// or camera (a phone is listed by 'sources' but never picked on its own).
struct SourceOptions: ParsableArguments {
    @Option(name: .long, help: "The source to use: an index or id from 'tethersnap sources' (default: the first attached console or camera).")
    var source: String?

    @Option(name: .long, help: "Open a folder instead of an attached source.", completion: .directory)
    var folder: String?

    func validate() throws {
        guard !(source != nil && folder != nil) else {
            throw ValidationError("--source and --folder exclude each other.")
        }
    }
}

enum CLIFormat {
    /// Fixed-width columns need the POSIX locale: with the user's locale a
    /// 12-hour clock preference rewrites `HH` to `h a`.
    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func url(_ path: String) -> URL {
        URL(filePath: (path as NSString).expandingTildeInPath)
    }

    static func display(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// `photo`, `raw`, or `video`, padded to the column width.
    static func kind(of item: CaptureItem) -> String {
        let name = item.kind == .video ? "video" : item.isRawImage ? "raw" : "photo"
        return name.padding(toLength: 5, withPad: " ", startingAt: 0)
    }
}

/// Diagnostics (`error:`, `warning:`, failures) go to stderr so stdout stays the
/// command's output (listings, progress, summaries) and can be piped.
enum CLIOutput {
    static func printError(_ line: String) {
        fflush(stdout) // keep ordering sane when both streams share a terminal
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Carriage-return progress lines only make sense on a terminal; piped
    /// output gets the final line per file only.
    static let isTerminal = isatty(STDOUT_FILENO) != 0

    static func progress(_ line: String) {
        guard isTerminal else { return }
        print("\r\(line)", terminator: "")
        fflush(stdout)
    }
}

/// Every command body runs through here so any error, not only the two kit
/// error enums, prints as `error: <localized>` on stderr and exits 1 instead
/// of ArgumentParser's `Error:` rendering.
enum CLIRun {
    static func perform(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch let exit as ExitCode {
            throw exit
        } catch {
            CLIOutput.printError("error: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }

    static func perform(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let exit as ExitCode {
            throw exit
        } catch {
            CLIOutput.printError("error: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

/// Ctrl-C as a clean cancel: the token fires, the running download or date
/// fix stops at the next chunk and removes its partial file, and the command
/// exits 130 after its summary. The source stays alive for the command's run.
final class CLIInterrupt {
    let token = CancelToken()
    private let source: DispatchSourceSignal

    init() {
        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let token = token
        source.setEventHandler { token.cancel() }
        source.resume()
    }

    deinit {
        source.cancel()
        signal(SIGINT, SIG_DFL)
    }

    static let exitCode = ExitCode(130)
}

enum CLISource {
    /// Open the chosen source, or print the localized error to stderr and exit nonzero.
    static func open(_ options: SourceOptions) throws -> any CaptureSource {
        if let folder = options.folder {
            return try CaptureSources.openFolder(CLIFormat.url(folder))
        }
        let attached = CaptureSources.attached()
        if let key = options.source {
            guard let descriptor = descriptor(for: key, in: attached) else {
                CLIOutput.printError("error: no source '\(key)' is attached (see 'tethersnap sources')")
                throw ExitCode.failure
            }
            return try CaptureSources.open(descriptor)
        }
        // Same rule as the app: a phone (.ptpDevice) is listed, never picked on its own.
        guard let first = attached.first(where: { $0.kind == .console || $0.kind == .camera }) else {
            throw MTPError.deviceNotFound
        }
        return try CaptureSources.open(first)
    }

    /// A 1-based index from `tethersnap sources`, or a descriptor id.
    static func descriptor(for key: String, in attached: [CaptureSourceDescriptor]) -> CaptureSourceDescriptor? {
        if let index = Int(key), attached.indices.contains(index - 1) {
            return attached[index - 1]
        }
        return attached.first { $0.id == key }
    }
}

/// Filters shared by `list` and `pull`.
struct KindOptions: ParsableArguments {
    @Flag(help: "Only photos.")
    var photosOnly = false

    @Flag(name: .customLong("screenshots-only"), help: .hidden)
    var screenshotsOnly = false

    @Flag(help: "Only videos.")
    var videosOnly = false

    func validate() throws {
        guard !((photosOnly || screenshotsOnly) && videosOnly) else {
            throw ValidationError("--photos-only and --videos-only exclude each other.")
        }
    }

    var kindFilter: CaptureItem.Kind? {
        if photosOnly || screenshotsOnly { return .image }
        if videosOnly { return .video }
        return nil
    }
}

// MARK: - sources

struct Sources: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List attached sources: USB devices and mounted drives."
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        options.apply()
        let attached = CaptureSources.attached()
        guard !attached.isEmpty else {
            print("No sources attached.")
            return
        }
        for (index, source) in attached.enumerated() {
            let kind = source.kind.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
            let detail = source.detail.map { "  (\($0))" } ?? ""
            print("[\(index + 1)] \(kind)  \(source.name)\(detail)")
            print("    id: \(source.id)")
        }
    }
}

// MARK: - probe

struct Probe: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Dump device, interface, and storage details (diagnostics)."
    )

    @OptionGroup var options: GlobalOptions
    @OptionGroup var sourceOptions: SourceOptions

    func run() throws {
        options.apply()
        try CLIRun.perform {
            let source = try CLISource.open(sourceOptions)
            defer { source.close() }

            if let connection = source as? TethersnapConnection {
                try probe(connection)
            } else if let volume = source as? VolumeCaptureSource {
                print("Source: \(volume.descriptor.name) (\(volume.descriptor.kind.rawValue))")
                print("Root:   \(CLIFormat.display(volume.root))")
                print("Layout: \(volume.layout.rawValue)")
                for mediaRoot in volume.layout.mediaRoots(under: volume.root) {
                    print("  Media folder: \(CLIFormat.display(mediaRoot))")
                }
            }

            let items = try source.loadItems()
            print("\nCaptures: \(items.count) (\(items.count(where: { $0.kind == .image })) photos, \(items.count(where: { $0.kind == .video })) videos)")
        }
    }

    private func probe(_ connection: TethersnapConnection) throws {
        print("Device: \(connection.deviceID.name) (\(connection.deviceID.hexPair))")
        if let location = connection.deviceID.locationID {
            print(String(format: "Location: 0x%08X", location))
        }
        if let serial = connection.deviceID.serialNumber, !serial.isEmpty {
            print("USB serial: \(serial)")
        }
        if let summary = connection.interfaceSummary {
            print(String(
                format: "Interface #%d class 0x%02X subclass 0x%02X protocol 0x%02X",
                summary.interfaceNumber, summary.interfaceClass, summary.interfaceSubclass, summary.interfaceProtocol
            ))
            let interrupt = summary.interruptInAddress.map { String(format: " interrupt-in 0x%02X", $0) } ?? ""
            print(String(format: "Endpoints: bulk-in 0x%02X bulk-out 0x%02X%@", summary.bulkInAddress, summary.bulkOutAddress, interrupt))
        }

        let info = connection.cachedDeviceInfo
        print("\nDeviceInfo")
        print("  Manufacturer:     \(info.manufacturer)")
        print("  Model:            \(info.model)")
        print("  Version:          \(info.deviceVersion)")
        print("  Serial:           \(info.serialNumber)")
        print(String(format: "  PTP version:      %.2f", Double(info.standardVersion) / 100))
        print(String(format: "  Vendor extension: 0x%08X \"%@\"", info.vendorExtensionID, info.vendorExtensionDescription))
        let operations = info.operationsSupported.map { String(format: "0x%04X", $0) }.joined(separator: " ")
        print("  Operations:       \(operations)")

        for storageID in try connection.session.storageIDs() {
            let storage = try connection.session.storageInfo(for: storageID)
            print(String(format: "\nStorage 0x%08X: %@", storageID, storage.displayName))
            // The Switch reports capacities as all-FF; don't render that as exabytes.
            let capacity = storage.maxCapacity == .max ? "unknown" : CaptureFormat.size(Int64(clamping: storage.maxCapacity))
            let free = storage.freeSpaceInBytes == .max ? "unknown" : CaptureFormat.size(Int64(clamping: storage.freeSpaceInBytes))
            print("  Capacity: \(capacity), free: \(free)")
        }
    }
}

// MARK: - list

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the photos and videos on a source."
    )

    @OptionGroup var kinds: KindOptions
    @OptionGroup var options: GlobalOptions
    @OptionGroup var sourceOptions: SourceOptions

    func run() throws {
        options.apply()
        try CLIRun.perform {
            let source = try CLISource.open(sourceOptions)
            defer { source.close() }

            let items = try source.loadItems().matching(kinds.kindFilter).sortedNewestFirst()
            guard !items.isEmpty else {
                print("No captures found.")
                return
            }
            for item in items {
                let date = item.date.map { CLIFormat.date.string(from: $0) } ?? "                "
                let folder = item.folderName.map { "\($0)/" } ?? ""
                print("\(date)  \(CLIFormat.kind(of: item))  \(CaptureFormat.size(item.sizeInBytes).padding(toLength: 10, withPad: " ", startingAt: 0))  \(folder)\(item.filename)")
            }
            print("\n\(items.count) captures")
        }
    }
}

// MARK: - pull

struct Pull: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Download photos and videos to a folder."
    )

    @Flag(help: "Download everything (optionally narrowed by --photos-only / --videos-only).")
    var all = false

    @Flag(help: "Skip files that already exist in the output folder.")
    var skipExisting = false

    @Option(name: [.short, .long], help: "Destination folder (default: ~/Pictures/Tethersnap).", completion: .directory)
    var out: String?

    @Argument(help: "Names to download, as 'tethersnap list' prints them (with or without the folder prefix).")
    var filenames: [String] = []

    @OptionGroup var kinds: KindOptions
    @OptionGroup var options: GlobalOptions
    @OptionGroup var sourceOptions: SourceOptions

    func validate() throws {
        guard all || !filenames.isEmpty else {
            throw ValidationError("Pass --all or one or more names from 'tethersnap list'.")
        }
    }

    func run() throws {
        options.apply()
        try CLIRun.perform {
            let source = try CLISource.open(sourceOptions)
            defer { source.close() }

            let directory = out.map(CLIFormat.url) ?? TethersnapDefaults.exportFolder
            let items = try source.loadItems().matching(kinds.kindFilter).sortedNewestFirst()
            let wanted: [CaptureItem]
            if all {
                wanted = items
            } else {
                // `list` prints `<folder>/<filename>`; accept that form, the bare
                // filename, and the disambiguated export name.
                let requested = Set(filenames)
                wanted = items.filter { item in
                    requested.contains(item.filename) || requested.contains(item.exportFilename)
                        || item.folderName.map { requested.contains("\($0)/\(item.filename)") } == true
                }
                let found = Set(wanted.flatMap { item in
                    [item.filename, item.exportFilename] + (item.folderName.map { ["\($0)/\(item.filename)"] } ?? [])
                })
                for name in requested.subtracting(found).sorted() {
                    CLIOutput.printError("warning: '\(name)' not found on the source, skipping")
                }
                // Naming files and getting none of them is a failure, not an empty success.
                guard !wanted.isEmpty else {
                    CLIOutput.printError("error: none of the named files are on the source (see 'tethersnap list')")
                    throw ExitCode.failure
                }
            }

            guard !wanted.isEmpty else {
                print("Nothing to download.")
                return
            }

            TemporaryFiles.reapStale(in: directory)
            let interrupt = CLIInterrupt()
            var downloaded = 0
            var skipped = 0
            var failed = 0
            var cancelled = false
            for (index, item) in wanted.enumerated() {
                let label = "[\(index + 1)/\(wanted.count)] \(item.exportFilename)"
                do {
                    let result = try source.download(item, to: directory, skipExisting: skipExisting, cancelToken: interrupt.token) { received, total in
                        guard total > 0 else { return }
                        CLIOutput.progress("\(label)  \(Int(received * 100 / total))%")
                    }
                    if result.skippedExisting {
                        print("\r\(label)  already exists, skipped")
                        skipped += 1
                    } else {
                        print("\r\(label)  done (\(CaptureFormat.size(item.sizeInBytes)))")
                        downloaded += 1
                    }
                } catch is CancellationError {
                    print("\r\(label)  cancelled")
                    cancelled = true
                    break
                } catch {
                    // One failed file costs that file, not the run; the summary and exit code say so.
                    CLIOutput.printError("\r\(label)  FAILED: \(error.localizedDescription)")
                    failed += 1
                    if error is MTPError, source is TethersnapConnection, !source.isValid {
                        CLIOutput.printError("error: the device session is out of sync; stopping (reconnect and run again)")
                        break
                    }
                }
            }
            let notes = [skipped > 0 ? "\(skipped) already existed" : nil, failed > 0 ? "\(failed) failed" : nil].compactMap(\.self)
            let suffix = notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))"
            print("\n\(downloaded) captures saved to \(directory.path)\(suffix)")
            if cancelled {
                throw CLIInterrupt.exitCode
            }
            if failed > 0 {
                throw ExitCode.failure
            }
        }
    }
}

// MARK: - fixdates

struct FixDates: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fixdates",
        abstract: "Set capture dates from the timestamps in filenames (EXIF, QuickTime, and Finder dates).",
        discussion: """
        Consoles, phones, and screenshot tools put the shot time in the filename (20260830123456…, \
        Game_20260830123456.jpg, Screenshot 2026-08-30 at 12.34.56.png). This stores it as the capture \
        date: EXIF and XMP for JPEG, PNG, TIFF, and HEIC, the QuickTime creation date for MP4/MOV \
        (the movie header and metadata box are patched in place, nothing is re-muxed or re-encoded), \
        and the Finder created/modified dates for every matched file. RAW, WebP, GIF, BMP, WebM, AVI, MTS, \
        and M2TS files get Finder dates only. A Sony clip's record (C0001M01.XML beside C0001.MP4, also \
        embedded in the clip) supplies the exact time with its zone, the camera make and model, and \
        the position when the camera had one, all embedded too; --no-clip-metadata ignores it. A date \
        already embedded in a file is kept unless --overwrite is given.
        """
    )

    @Argument(help: "Files or folders to fix.", completion: .file())
    var paths: [String]

    @Flag(help: "Replace dates already embedded in the files.")
    var overwrite = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Descend into subfolders.")
    var recursive = true

    @Flag(help: "Report what would change without writing anything.")
    var dryRun = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Use a Sony clip's record (its M01.XML, or the copy inside the clip) for the exact time, time zone, camera make and model, and position.")
    var clipMetadata = true

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        options.apply()
        try await CLIRun.perform {
            var files: [URL] = []
            for path in paths {
                let url = CLIFormat.url(path)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    CLIOutput.printError("error: '\(path)' does not exist")
                    throw ExitCode.failure
                }
                if FileSystem.isDirectory(url) {
                    try files.append(contentsOf: CaptureDateFixer.candidates(in: url, recursive: recursive))
                } else {
                    files.append(url)
                }
            }
            guard !files.isEmpty else {
                print("No files to fix.")
                return
            }

            let fixer = CaptureDateFixer(options: .init(overwrite: overwrite, recursive: recursive, dryRun: dryRun, clipMetadata: clipMetadata))
            let dryRun = dryRun
            let interrupt = CLIInterrupt()
            let report = await fixer.fix(files: files, cancelToken: interrupt.token, onOutcome: { entry in
                let path = CLIFormat.display(entry.url)
                switch entry.outcome {
                case let .updated(date, embedded):
                    let verb = dryRun ? "would update" : "updated"
                    let scope = embedded ? "" : ", file dates only"
                    print("\(path)  \(verb)\(scope) (\(CLIFormat.dateTime.string(from: date)))")
                case let .alreadyDated(date):
                    print("\(path)  already dated (\(CLIFormat.dateTime.string(from: date)))")
                case .noDateInName:
                    print("\(path)  no date in name")
                case .unsupported:
                    print("\(path)  unsupported")
                case let .failed(error):
                    CLIOutput.printError("\(path)  FAILED: \(error.localizedDescription)")
                }
            })

            let summary = "\(report.updated.count) \(dryRun ? "would be updated" : "updated"), \(report.alreadyDated.count) already dated, "
                + "\(report.noDateInName.count) without a date in the name, \(report.unsupported.count) unsupported, \(report.failed.count) failed"
            print("\n\(summary)\(report.cancelled ? " (cancelled)" : "")")
            if report.cancelled {
                throw CLIInterrupt.exitCode
            }
            if !report.failed.isEmpty {
                throw ExitCode.failure
            }
        }
    }
}
