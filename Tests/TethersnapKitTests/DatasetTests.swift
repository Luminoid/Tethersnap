import Foundation
import Testing
@testable import TethersnapKit

enum Fixtures {
    /// DeviceInfo dataset mirroring the REAL console (probed 2026-08-30,
    /// firmware 22.5.0): PTP 1.00, no MTP vendor extension (0xFFFFFFFF,
    /// description "nintendo.com: 1.0; "), baseline operations 0x1001-0x100A
    /// (GetThumb yes, GetPartialObject NO). Serial is shape-alike, not real.
    static func switch2DeviceInfo() -> Data {
        var writer = PTPDataWriter()
        writer.appendU16(100)
        writer.appendU32(0xFFFF_FFFF)
        writer.appendU16(110)
        writer.appendString("nintendo.com: 1.0; ")
        writer.appendU16(0)
        writer.appendU16Array([0x1001, 0x1002, 0x1003, 0x1004, 0x1005, 0x1006, 0x1007, 0x1008, 0x1009, 0x100A])
        writer.appendU16Array([])
        writer.appendU16Array([])
        writer.appendU16Array([])
        writer.appendU16Array([0x3801, 0xB982])
        writer.appendString("Nintendo")
        writer.appendString("Nintendo Switch 2")
        writer.appendString("22.5.0")
        writer.appendString("HAW00000000000")
        return writer.data
    }

    static func objectInfo(filename: String,
                           format: UInt16 = 0x3801,
                           size: UInt32 = 412_233,
                           thumbSize: UInt32 = 0,
                           captureDate: String = "20260829T170512",
                           parent: UInt32 = 0x0000_0010,
                           storageID: UInt32 = 0x0001_0001) -> Data {
        var writer = PTPDataWriter()
        writer.appendU32(storageID)
        writer.appendU16(format)
        writer.appendU16(0) // protection
        writer.appendU32(size)
        writer.appendU16(thumbSize > 0 ? 0x3801 : 0) // thumb format
        writer.appendU32(thumbSize)
        writer.appendU32(0)
        writer.appendU32(0)
        writer.appendU32(1920)
        writer.appendU32(1080)
        writer.appendU32(24)
        writer.appendU32(parent)
        writer.appendU16(format == PTPObjectFormat.association ? 1 : 0)
        writer.appendU32(0)
        writer.appendU32(0)
        writer.appendString(filename)
        writer.appendString(captureDate)
        writer.appendString("")
        writer.appendString("")
        return writer.data
    }

    /// Mirrors the real console's storage 0x000F0001: capacities unreported (all-FF).
    static func storageInfo() -> Data {
        var writer = PTPDataWriter()
        writer.appendU16(0x0001) // fixed ROM
        writer.appendU16(0x0002) // generic hierarchical
        writer.appendU16(0x0001) // read-only without deletion
        writer.appendU64(.max)
        writer.appendU64(.max)
        writer.appendU32(0xFFFF_FFFF)
        writer.appendString("Album")
        writer.appendString("")
        return writer.data
    }
}

@Suite("PTP datasets")
struct DatasetTests {
    @Test
    func `DeviceInfo dataset decodes the Switch 2 profile`() throws {
        let info = try PTPDeviceInfo.decode(Fixtures.switch2DeviceInfo())

        #expect(info.standardVersion == 100)
        #expect(info.vendorExtensionID == 0xFFFF_FFFF)
        #expect(info.model == "Nintendo Switch 2")
        #expect(info.manufacturer == "Nintendo")
        #expect(info.supports(.getObject))
        #expect(info.supports(.getThumb))
        #expect(!info.supports(.getPartialObject))
    }

    @Test
    func `ObjectInfo dataset decodes filename, size, and capture date`() throws {
        let info = try PTPObjectInfo.decode(Fixtures.objectInfo(filename: "2026082917051200-CAFE.jpg"))

        #expect(info.filename == "2026082917051200-CAFE.jpg")
        #expect(info.compressedSize == 412_233)
        #expect(info.objectFormat == 0x3801)
        #expect(!info.isAssociation)
        let date = try #require(info.bestDate)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        #expect(calendar.dateComponents([.hour], from: date).hour == 17)
    }

    @Test
    func `ObjectInfo without dataset dates falls back to the filename timestamp`() throws {
        let info = try PTPObjectInfo.decode(Fixtures.objectInfo(filename: "2026010109300000-BEEF.mp4", captureDate: ""))

        let date = try #require(info.bestDate)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        #expect(calendar.dateComponents([.month], from: date).month == 1)
    }

    @Test
    func `Association entries are recognized as folders`() throws {
        let info = try PTPObjectInfo.decode(Fixtures.objectInfo(filename: "Album", format: PTPObjectFormat.association))

        #expect(info.isAssociation)
    }

    @Test
    func `StorageInfo dataset decodes capacity and naming`() throws {
        let info = try PTPStorageInfo.decode(Fixtures.storageInfo())

        #expect(info.maxCapacity == .max) // the console reports capacities as all-FF "unknown"
        #expect(info.storageDescription == "Album")
        #expect(info.displayName == "Album")
    }

    @Test
    func `Truncated datasets throw malformedData instead of crashing`() {
        let full = Fixtures.switch2DeviceInfo()

        #expect(throws: MTPError.self) { _ = try PTPDeviceInfo.decode(full.prefix(10)) }
        #expect(throws: MTPError.self) { _ = try PTPObjectInfo.decode(Data([0x01, 0x02, 0x03])) }
    }
}
