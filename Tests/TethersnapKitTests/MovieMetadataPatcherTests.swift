import AVFoundation
import Foundation
import Testing
@testable import TethersnapKit

@Suite("Movie metadata patcher")
struct MovieMetadataPatcherTests {
    static let zone = TimeZone(secondsFromGMT: -7 * 3600) ?? .current
    /// 2026-08-30 12:34:56 in the record's zone, whatever the machine's is.
    static let date = MetadataDate.date(year: 2026, month: 8, day: 30, hour: 12, minute: 34, second: 56, zone: zone) ?? Date()
    static let xml = Data(SonyClipMetadataTests.record.utf8)

    static var metadata: MovieMetadataPatcher.Metadata {
        MovieMetadataPatcher.Metadata(
            creationDate: date, timeZone: zone, make: "Sony", model: "ILCE-7M3",
            location: .init(latitude: 37.415_602_5, longitude: -121.957_866)
        )
    }

    @Test
    func `A QuickTime movie gains the date, make, and model keys AVFoundation reads back`() async throws {
        let directory = try ImageDateWriterTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("C0001.mov")
        try await VideoDateWriterTests.writeMovie(at: url, fileType: .mov, codec: .jpeg)
        let (tracksBefore, durationBefore) = try await VideoDateWriterTests.shape(of: url)

        try MovieMetadataPatcher.patch(url, with: Self.metadata)

        let items = try await Self.items(at: url)
        #expect(items[.quickTimeMetadataCreationDate] == ["2026-08-30T12:34:56-0700"])
        #expect(items[.quickTimeMetadataMake] == ["Sony"])
        #expect(items[.quickTimeMetadataModel] == ["ILCE-7M3"])
        #expect(items[.quickTimeMetadataLocationISO6709] == ["+37.4156-121.9579/"])
        #expect(try await VideoDateWriter.embeddedLocation(at: url) == "+37.4156-121.9579/")
        let readBack = try #require(try await VideoDateWriter.embeddedDate(at: url))
        #expect(abs(readBack.timeIntervalSince(Self.date)) < 1)
        #expect(try await VideoDateWriter.embeddedMake(at: url) == "Sony")
        let (tracksAfter, durationAfter) = try await VideoDateWriterTests.shape(of: url)
        #expect(tracksAfter == tracksBefore)
        #expect(durationAfter == durationBefore)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [url.lastPathComponent])
    }

    @Test
    func `An H.264 MP4 takes the same keys`() async throws {
        let directory = try ImageDateWriterTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("C0001.mp4")
        try await VideoDateWriterTests.writeMovie(at: url, fileType: .mp4, codec: .h264)
        let (_, durationBefore) = try await VideoDateWriterTests.shape(of: url)

        try MovieMetadataPatcher.patch(url, with: Self.metadata)

        let items = try await Self.items(at: url)
        #expect(items[.quickTimeMetadataCreationDate] == ["2026-08-30T12:34:56-0700"])
        #expect(items[.quickTimeMetadataModel] == ["ILCE-7M3"])
        let (tracksAfter, durationAfter) = try await VideoDateWriterTests.shape(of: url)
        #expect(tracksAfter == 1)
        #expect(durationAfter == durationBefore)
    }

    @Test
    func `Patching again replaces the values instead of adding keys`() async throws {
        let directory = try ImageDateWriterTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("C0001.mov")
        try await VideoDateWriterTests.writeMovie(at: url, fileType: .mov, codec: .jpeg)

        try MovieMetadataPatcher.patch(url, with: Self.metadata)
        var second = Self.metadata
        second.make = "Canon"
        second.model = nil
        try MovieMetadataPatcher.patch(url, with: second)

        let items = try await Self.items(at: url)
        #expect(items[.quickTimeMetadataMake] == ["Canon"])
        #expect(items[.quickTimeMetadataModel] == ["ILCE-7M3"]) // untouched: nil means "leave as is"
        #expect(items[.quickTimeMetadataCreationDate]?.count == 1)
    }

    @Test
    func `A movie with moov after mdat is rewritten from the tail and keeps its trailing boxes`() throws {
        let directory = try ImageDateWriterTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("C0001.MP4")
        let original = Self.syntheticMovie(moovFirst: false, headerVersion: 0, xml: Self.xml)
        try original.write(to: url)
        let moovOffset = try #require(Self.topLevel(of: original).first { $0.type == "moov" }?.offset)
        let trailing = try #require(Self.topLevel(of: original).last)

        try MovieMetadataPatcher.patch(url, with: Self.metadata)

        let patched = try Data(contentsOf: url)
        let boxes = try Self.topLevel(of: patched)
        #expect(boxes.map(\.type) == ["ftyp", "mdat", "moov", "meta"])
        #expect(patched.prefix(Int(moovOffset)) == original.prefix(Int(moovOffset)))
        let newMeta = try #require(boxes.last)
        #expect(MovieMetadataPatcher.slice(patched, newMeta.offset, newMeta.size) == MovieMetadataPatcher.slice(original, trailing.offset, trailing.size))
        let moov = try #require(boxes.first { $0.type == "moov" })
        let payload = MovieMetadataPatcher.slice(patched, moov.payloadOffset, moov.payloadSize)
        #expect(try MovieMetadataPatcher.metadataKeys(ofMoovPayload: payload) == [
            MovieMetadataPatcher.creationDateKey: "2026-08-30T12:34:56-0700",
            MovieMetadataPatcher.makeKey: "Sony",
            MovieMetadataPatcher.modelKey: "ILCE-7M3",
            MovieMetadataPatcher.locationKey: "+37.4156-121.9579/",
        ])
        let seconds = MovieMetadataPatcher.quickTimeSeconds(Self.date)
        #expect(try Self.headerTimes(inMoovPayload: payload) == [seconds, seconds, seconds])
        #expect(try MovieMetadataPatcher.embeddedXML(at: url) == Self.xml)
    }

    @Test
    func `A movie with moov before mdat keeps mdat in place and appends the new moov`() throws {
        let directory = try ImageDateWriterTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("C0001.mov")
        let original = Self.syntheticMovie(moovFirst: true, headerVersion: 1, xml: nil)
        try original.write(to: url)
        let oldMoov = try #require(Self.topLevel(of: original).first { $0.type == "moov" })
        let mdat = try #require(Self.topLevel(of: original).first { $0.type == "mdat" })

        try MovieMetadataPatcher.patch(url, with: Self.metadata)

        let patched = try Data(contentsOf: url)
        let boxes = try Self.topLevel(of: patched)
        #expect(boxes.map(\.type) == ["ftyp", "free", "mdat", "moov"])
        #expect(boxes[1].offset == oldMoov.offset)
        #expect(boxes[1].size == oldMoov.size)
        #expect(boxes[2] == mdat)
        #expect(MovieMetadataPatcher.slice(patched, mdat.offset, mdat.size) == MovieMetadataPatcher.slice(original, mdat.offset, mdat.size))
        let moov = try #require(boxes.last)
        let payload = MovieMetadataPatcher.slice(patched, moov.payloadOffset, moov.payloadSize)
        #expect(try MovieMetadataPatcher.metadataKeys(ofMoovPayload: payload)[MovieMetadataPatcher.makeKey] == "Sony")
        let seconds = MovieMetadataPatcher.quickTimeSeconds(Self.date)
        #expect(try Self.headerTimes(inMoovPayload: payload) == [seconds, seconds, seconds])
    }

    @Test
    func `Files that are not movies are refused untouched`() throws {
        let directory = try ImageDateWriterTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = directory.appendingPathComponent("fake.mov")
        try Data("not a movie".utf8).write(to: text)
        let twoMoovs = directory.appendingPathComponent("two.mov")
        let moov = MovieMetadataPatcher.box("moov", Self.movieHeader(version: 0))
        try (MovieMetadataPatcher.box("ftyp", Data("isom".utf8)) + moov + moov).write(to: twoMoovs)

        #expect(throws: DateFixError.self) { try MovieMetadataPatcher.patch(text, with: Self.metadata) }
        #expect(throws: DateFixError.self) { try MovieMetadataPatcher.patch(twoMoovs, with: Self.metadata) }

        #expect(try Data(contentsOf: text) == Data("not a movie".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["fake.mov", "two.mov"])
    }

    // MARK: - Fixtures

    /// `ftyp`, `mdat`, and a `moov` with one track (empty headers), in either
    /// order, plus Sony's top-level `meta/xml` box when `xml` is given.
    static func syntheticMovie(moovFirst: Bool, headerVersion: UInt8, xml: Data?) -> Data {
        let ftyp = MovieMetadataPatcher.box("ftyp", Data("isom".utf8) + MovieMetadataPatcher.bigEndian(UInt32(0)) + Data("isom".utf8))
        let mdat = MovieMetadataPatcher.box("mdat", Data("SAMPLES!".utf8))
        let mdhd = MovieMetadataPatcher.box("mdhd", fullBoxPayload(version: headerVersion, bytes: headerVersion == 1 ? 32 : 20))
        let tkhd = MovieMetadataPatcher.box("tkhd", fullBoxPayload(version: headerVersion, bytes: headerVersion == 1 ? 92 : 80))
        let trak = MovieMetadataPatcher.box("trak", tkhd + MovieMetadataPatcher.box("mdia", mdhd))
        let moov = MovieMetadataPatcher.box("moov", MovieMetadataPatcher.box("mvhd", movieHeader(version: headerVersion)) + trak)
        var file = ftyp + (moovFirst ? moov + mdat : mdat + moov)
        if let xml {
            var handler = Data(count: 8)
            handler.append(Data("null".utf8))
            handler.append(Data(count: 13))
            let meta = Data(count: 4) + MovieMetadataPatcher.box("hdlr", handler) + MovieMetadataPatcher.box("xml ", Data(count: 4) + xml)
            file.append(MovieMetadataPatcher.box("meta", meta))
        }
        return file
    }

    static func movieHeader(version: UInt8) -> Data {
        fullBoxPayload(version: version, bytes: version == 1 ? 108 : 96)
    }

    /// Version, three flag bytes, then `bytes` zero bytes.
    private static func fullBoxPayload(version: UInt8, bytes: Int) -> Data {
        Data([version, 0, 0, 0]) + Data(count: bytes)
    }

    static func topLevel(of data: Data) throws -> [MovieMetadataPatcher.Box] {
        try MovieMetadataPatcher.boxes(in: data)
    }

    /// The creation times of the `mvhd`, the first `tkhd`, and the first `mdhd`.
    static func headerTimes(inMoovPayload payload: Data) throws -> [UInt64] {
        func time(_ box: MovieMetadataPatcher.Box, in data: Data) -> UInt64 {
            let body = MovieMetadataPatcher.slice(data, box.payloadOffset, box.payloadSize)
            let width = body[0] == 1 ? 8 : 4
            return body[4 ..< 4 + width].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        let children = try MovieMetadataPatcher.boxes(in: payload)
        let mvhd = try #require(children.first { $0.type == "mvhd" })
        let trak = try #require(children.first { $0.type == "trak" })
        let trakChildren = try MovieMetadataPatcher.boxes(in: payload, range: trak.payloadOffset ..< trak.end)
        let tkhd = try #require(trakChildren.first { $0.type == "tkhd" })
        let mdia = try #require(trakChildren.first { $0.type == "mdia" })
        let mdhd = try #require(try MovieMetadataPatcher.boxes(in: payload, range: mdia.payloadOffset ..< mdia.end).first { $0.type == "mdhd" })
        return [time(mvhd, in: payload), time(tkhd, in: payload), time(mdhd, in: payload)]
    }

    /// Every string value per identifier, so duplicate keys show up.
    static func items(at url: URL) async throws -> [AVMetadataIdentifier: [String]] {
        var result: [AVMetadataIdentifier: [String]] = [:]
        for item in try await AVURLAsset(url: url).load(.metadata) {
            guard let identifier = item.identifier, let value = try await item.load(.stringValue) else { continue }
            result[identifier, default: []].append(value)
        }
        return result
    }
}
