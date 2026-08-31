import ArgumentParser
import Foundation
import TethersnapKit

@main
struct Tethersnap: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tethersnap",
        abstract: "Export Nintendo Switch 2 screenshots and videos over USB.",
        discussion: """
        On the console: System Settings → Data Management → Manage Screenshots and Videos \
        → Copy to PC via USB. Use the BOTTOM USB-C port with a full-data cable (not the dock).

        Tethersnap is an independent project, not affiliated with or endorsed by Nintendo.
        """,
        version: "0.1.0",
        subcommands: [Probe.self, List.self, Pull.self],
        defaultSubcommand: List.self
    )
}

// MARK: - Helpers

struct GlobalOptions: ParsableArguments {
    @Flag(name: [.short, .long], help: "Mirror debug logs (USB transfers, PTP transactions) to stderr.")
    var verbose = false

    func apply() {
        TethersnapLog.echoToStderr = verbose
    }
}

enum CLIFormat {
    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

enum CLIConnection {
    /// Connect or print the localized error and exit nonzero.
    static func open() throws -> TethersnapConnection {
        do {
            return try TethersnapConnection.connect()
        } catch let error as MTPError {
            print("error: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

extension [CaptureItem] {
    /// Newest first, undated items last (the order `list` prints and `pull` downloads).
    func newestFirst() -> [CaptureItem] {
        sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}

// MARK: - probe

struct Probe: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Dump device, interface, and storage details (diagnostics)."
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        options.apply()
        let connection = try CLIConnection.open()
        defer { connection.close() }

        print("Device: \(connection.deviceID.name) "
            + String(format: "(%04x:%04x)", connection.deviceID.vendorID, connection.deviceID.productID))
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
            // The console reports capacities as all-FF; don't render that as exabytes.
            let capacity = storage.maxCapacity == .max ? "unknown" : CaptureFormat.size(Int64(clamping: storage.maxCapacity))
            let free = storage.freeSpaceInBytes == .max ? "unknown" : CaptureFormat.size(Int64(clamping: storage.freeSpaceInBytes))
            print("  Capacity: \(capacity), free: \(free)")
        }

        let items = try connection.library.loadItems()
        print("\nCaptures: \(items.count) (\(items.count(where: { $0.kind == .screenshot })) screenshots, \(items.count(where: { $0.kind == .video })) videos)")
    }
}

// MARK: - list

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List captures on the console."
    )

    @Flag(help: "Only screenshots.")
    var screenshotsOnly = false

    @Flag(help: "Only videos.")
    var videosOnly = false

    @OptionGroup var options: GlobalOptions

    func validate() throws {
        guard !(screenshotsOnly && videosOnly) else {
            throw ValidationError("--screenshots-only and --videos-only exclude each other.")
        }
    }

    private var kindFilter: CaptureItem.Kind? {
        if screenshotsOnly { return .screenshot }
        if videosOnly { return .video }
        return nil
    }

    func run() throws {
        options.apply()
        let connection = try CLIConnection.open()
        defer { connection.close() }

        let items = try connection.library.loadItems().matching(kindFilter).newestFirst()
        guard !items.isEmpty else {
            print("No captures found.")
            return
        }
        for item in items {
            let date = item.date.map { CLIFormat.date.string(from: $0) } ?? "                "
            let kind = item.kind == .video ? "video     " : "screenshot"
            print("\(date)  \(kind)  \(CaptureFormat.size(item.sizeInBytes).padding(toLength: 10, withPad: " ", startingAt: 0))  \(item.filename)")
        }
        print("\n\(items.count) captures")
    }
}

// MARK: - pull

struct Pull: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Download captures to a folder."
    )

    @Flag(help: "Download everything.")
    var all = false

    @Flag(help: "Skip files that already exist in the output folder.")
    var skipExisting = false

    @Option(name: [.short, .long], help: "Destination folder (default: ~/Pictures/Switch2).", completion: .directory)
    var out: String?

    @Argument(help: "Filenames to download (as shown by 'tethersnap list').")
    var filenames: [String] = []

    @OptionGroup var options: GlobalOptions

    func validate() throws {
        guard all || !filenames.isEmpty else {
            throw ValidationError("Pass --all or one or more filenames from 'tethersnap list'.")
        }
    }

    func run() throws {
        options.apply()
        let connection = try CLIConnection.open()
        defer { connection.close() }

        let directory = out.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? TethersnapDefaults.exportFolder
        let items = try connection.library.loadItems().newestFirst()
        let wanted: [CaptureItem]
        if all {
            wanted = items
        } else {
            let requested = Set(filenames)
            wanted = items.filter { requested.contains($0.filename) }
            let missing = requested.subtracting(wanted.map(\.filename))
            for name in missing.sorted() {
                print("warning: '\(name)' not found on the console, skipping")
            }
        }

        guard !wanted.isEmpty else {
            print("Nothing to download.")
            return
        }

        var downloaded = 0
        var skipped = 0
        for (index, item) in wanted.enumerated() {
            let label = "[\(index + 1)/\(wanted.count)] \(item.exportFilename)"
            do {
                let result = try connection.library.download(item, to: directory, skipExisting: skipExisting) { received, total in
                    guard total > 0 else { return }
                    let percent = Int(received * 100 / total)
                    print("\r\(label)  \(percent)%", terminator: "")
                    fflush(stdout)
                }
                if result.skippedExisting {
                    print("\r\(label)  already exists, skipped")
                    skipped += 1
                } else {
                    print("\r\(label)  done (\(CaptureFormat.size(item.sizeInBytes)))")
                    downloaded += 1
                }
            } catch {
                print("\r\(label)  FAILED: \(error.localizedDescription)")
                throw ExitCode.failure
            }
        }
        let skippedNote = skipped > 0 ? " (\(skipped) already existed)" : ""
        print("\n\(downloaded) captures saved to \(directory.path)\(skippedNote)")
    }
}
