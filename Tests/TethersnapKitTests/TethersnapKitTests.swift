import Foundation
import Testing
@testable import TethersnapKit

@Suite("PTP primitives")
struct PTPPrimitivesTests {
    @Test
    func `Container header round-trips through encode and decode`() throws {
        let header = PTPContainerHeader(length: 24, type: .command, code: PTPOperationCode.getObjectHandles.rawValue, transactionID: 7)

        let decoded = try PTPContainerHeader.decode(header.encoded())

        #expect(decoded == header)
        #expect(decoded.payloadLength == 12)
    }

    @Test
    func `Container decode rejects short data, unknown types, and undersized lengths`() {
        var writer = PTPDataWriter()
        writer.appendU32(16)
        writer.appendU16(9) // no such container type
        writer.appendU16(0x1001)
        writer.appendU32(1)
        let badType = writer.data

        var shortLength = PTPDataWriter()
        shortLength.appendU32(4) // below the 12-byte header
        shortLength.appendU16(1)
        shortLength.appendU16(0x1001)
        shortLength.appendU32(1)

        #expect(throws: MTPError.self) { try PTPContainerHeader.decode(Data([0x01, 0x02])) }
        #expect(throws: MTPError.self) { try PTPContainerHeader.decode(badType) }
        #expect(throws: MTPError.self) { try PTPContainerHeader.decode(shortLength.data) }
    }

    @Test
    func `Command containers carry little-endian parameters after the header`() throws {
        let command = try PTPContainer.command(.getObject, transactionID: 3, parameters: [0x0000_0042])

        #expect(command.count == 16)
        #expect([UInt8](command.prefix(4)) == [16, 0, 0, 0])
        #expect([UInt8](command[4 ..< 8]) == [1, 0, 0x09, 0x10])
        #expect([UInt8](command[12 ..< 16]) == [0x42, 0, 0, 0])
    }

    @Test
    func `Command containers reject more than five parameters instead of trapping`() {
        #expect(throws: MTPError.self) {
            _ = try PTPContainer.command(.getObject, transactionID: 1, parameters: [1, 2, 3, 4, 5, 6])
        }
    }

    @Test
    func `Reader and writer round-trip integers, arrays, and strings`() throws {
        var writer = PTPDataWriter()
        writer.appendU8(0xAB)
        writer.appendU16(0xBEEF)
        writer.appendU32(0xDEAD_BEEF)
        writer.appendU64(0x0123_4567_89AB_CDEF)
        writer.appendU16Array([1, 2, 3])
        writer.appendU32Array([])
        writer.appendString("Switch 2 スクショ")
        writer.appendString("")

        var reader = PTPDataReader(writer.data)

        #expect(try reader.readU8() == 0xAB)
        #expect(try reader.readU16() == 0xBEEF)
        #expect(try reader.readU32() == 0xDEAD_BEEF)
        #expect(try reader.readU64() == 0x0123_4567_89AB_CDEF)
        #expect(try reader.readU16Array() == [1, 2, 3])
        #expect(try reader.readU32Array() == [])
        #expect(try reader.readString() == "Switch 2 スクショ")
        #expect(try reader.readString() == "")
        #expect(reader.remainingCount == 0)
    }

    @Test
    func `Reader throws instead of crashing on truncated input`() {
        var reader = PTPDataReader(Data([0x01]))

        #expect(throws: MTPError.self) { _ = try reader.readU32() }
    }

    @Test
    func `Strings without the counted null terminator still decode`() throws {
        var writer = PTPDataWriter()
        writer.appendU8(2)
        writer.appendU16(UInt16(UnicodeScalar("A").value))
        writer.appendU16(UInt16(UnicodeScalar("B").value)) // terminator slot used by a real char

        var reader = PTPDataReader(writer.data)

        #expect(try reader.readString() == "AB")
    }

    @Test
    func `Overlong strings truncate with a terminator and never split a surrogate pair`() throws {
        var plain = PTPDataWriter()
        plain.appendString(String(repeating: "A", count: 300))
        var reader = PTPDataReader(plain.data)
        let decoded = try reader.readString()
        #expect(plain.data.count == 1 + 255 * 2) // count byte + 254 chars + terminator
        #expect(decoded == String(repeating: "A", count: 254))

        // 253 chars then a surrogate pair straddling the 254-unit cut.
        var surrogate = PTPDataWriter()
        surrogate.appendString(String(repeating: "A", count: 253) + "𝄞𝄞")
        var surrogateReader = PTPDataReader(surrogate.data)
        let surrogateDecoded = try surrogateReader.readString()
        #expect(surrogateDecoded == String(repeating: "A", count: 253))
        #expect(!surrogateDecoded.unicodeScalars.contains { $0.value == 0xFFFD })
    }

    @Test
    func `Code descriptions are explicit name maps, never recursive`() {
        // PTPOperationCode.description once used String(describing: self) on
        // itself: infinite recursion, SIGBUS. Lock the fix in.
        #expect(PTPOperationCode.getObject.description.contains("GetObject"))
        #expect(PTPOperationCode.getPartialObject.description.contains("0x101B"))
        #expect(PTPResponseCode.ok.description.contains("OK"))
        #expect(PTPResponseCode(rawValue: 0xA5A5).description == "0xA5A5")
    }
}

@Suite("PTP date parsing")
struct PTPDateParserTests {
    @Test
    func `Parses the plain PTP DateTime form in local time`() throws {
        let date = try #require(PTPDateParser.parse("20260829T142530"))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(components.year == 2026)
        #expect(components.month == 8)
        #expect(components.day == 29)
        #expect(components.hour == 14)
        #expect(components.minute == 25)
        #expect(components.second == 30)
    }

    @Test
    func `Honors tenths and UTC / offset zone suffixes`() throws {
        let utc = try #require(PTPDateParser.parse("20260101T000000.0Z"))
        let offset = try #require(PTPDateParser.parse("20260101T080000+0800"))

        #expect(utc == offset)
    }

    @Test
    func `Extracts the timestamp prefix of Switch capture filenames`() throws {
        let date = try #require(PTPDateParser.parseFilenameTimestamp("2026082917051234-A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6.jpg"))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .hour, .second], from: date)
        #expect(components.year == 2026)
        #expect(components.hour == 17)
        #expect(components.second == 12)
    }

    @Test
    func `Rejects garbage instead of producing a date`() {
        #expect(PTPDateParser.parse("not a date") == nil)
        #expect(PTPDateParser.parse("20260829142530") == nil) // missing T
        #expect(PTPDateParser.parseFilenameTimestamp("IMG_1234.jpg") == nil)
    }
}
