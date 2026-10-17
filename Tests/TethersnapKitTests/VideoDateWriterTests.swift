import AVFoundation
import Foundation
import Testing
@testable import TethersnapKit

@Suite("Video date writer")
struct VideoDateWriterTests {
    @Test
    func `A QuickTime movie without a creation date gains one and keeps its track and duration`() async throws {
        let directory = try ImageDateWriterTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("2026083012345600-CAFE.mov")
        try await Self.writeMovie(at: url, fileType: .mov, codec: .jpeg)
        try Self.zeroMovieHeaderTimes(at: url)
        let (tracksBefore, durationBefore) = try await Self.shape(of: url)
        let date = ImageDateWriterTests.fixtureDate

        #expect(try await VideoDateWriter.embeddedDate(at: url) == nil)
        try await VideoDateWriter.write(date, to: url, cancelToken: nil)

        let readBack = try #require(try await VideoDateWriter.embeddedDate(at: url))
        #expect(abs(readBack.timeIntervalSince(date)) < 1)
        let (tracksAfter, durationAfter) = try await Self.shape(of: url)
        #expect(tracksAfter == tracksBefore)
        #expect(tracksAfter == 1)
        #expect(durationAfter == durationBefore)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [url.lastPathComponent])
    }

    @Test
    func `An H.264 MP4 round-trips its creation date the same way`() async throws {
        let directory = try ImageDateWriterTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Astro's Playroom_20260830123456.mp4")
        try await Self.writeMovie(at: url, fileType: .mp4, codec: .h264)
        try Self.zeroMovieHeaderTimes(at: url)
        let (_, durationBefore) = try await Self.shape(of: url)
        let date = ImageDateWriterTests.fixtureDate

        #expect(try await VideoDateWriter.embeddedDate(at: url) == nil)
        try await VideoDateWriter.write(date, to: url, cancelToken: nil)

        let readBack = try #require(try await VideoDateWriter.embeddedDate(at: url))
        #expect(abs(readBack.timeIntervalSince(date)) < 1)
        let (tracksAfter, durationAfter) = try await Self.shape(of: url)
        #expect(tracksAfter == 1)
        #expect(durationAfter == durationBefore)
    }

    @Test
    func `The movie header time counts as a date until an explicit tag overrides it`() async throws {
        // AVAssetWriter (like every muxer) stamps the movie header with the mux time, which
        // AVAsset.creationDate synthesizes into a common/creationDate item. After a write the
        // explicit tag must win over the re-mux time the new header carries.
        let directory = try ImageDateWriterTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("2026083012345600-CAFE.mov")
        try await Self.writeMovie(at: url, fileType: .mov, codec: .jpeg)
        let date = ImageDateWriterTests.fixtureDate

        let headerTime = try #require(try await VideoDateWriter.embeddedDate(at: url))
        #expect(abs(headerTime.timeIntervalSinceNow) < 60)
        try await VideoDateWriter.write(date, to: url, cancelToken: nil)

        let readBack = try #require(try await VideoDateWriter.embeddedDate(at: url))
        #expect(abs(readBack.timeIntervalSince(date)) < 1)
    }

    @Test
    func `A fired cancel token aborts the write and leaves the file untouched`() async throws {
        let directory = try ImageDateWriterTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("2026083012345600-CAFE.mov")
        try await Self.writeMovie(at: url, fileType: .mov, codec: .jpeg)
        let before = try Data(contentsOf: url)
        let token = CancelToken()
        token.cancel()

        await #expect(throws: CancellationError.self) {
            try await VideoDateWriter.write(ImageDateWriterTests.fixtureDate, to: url, cancelToken: token)
        }

        #expect(try Data(contentsOf: url) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [url.lastPathComponent])
    }

    @Test
    func `A file that is not a movie fails with a date-fix error`() async throws {
        let directory = try ImageDateWriterTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fake.mov")
        try Data("not a movie".utf8).write(to: url)

        await #expect(throws: (any Error).self) {
            try await VideoDateWriter.write(ImageDateWriterTests.fixtureDate, to: url, cancelToken: nil)
        }

        #expect(try Data(contentsOf: url) == Data("not a movie".utf8))
    }

    // MARK: - Fixtures

    /// Two 64×64 frames at 30 fps; `.jpeg` stays on the software encoder.
    static func writeMovie(at url: URL, fileType: AVFileType, codec: AVVideoCodecType) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let settings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: 64, AVVideoHeightKey: 64]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? MTPError.malformedData("asset writer could not start")
        }
        writer.startSession(atSourceTime: .zero)
        for frame in 0 ..< 2 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }
            let buffer = try makePixelBuffer(from: adaptor, fill: frame == 0 ? 0x40 : 0xC0)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)) else {
                throw writer.error ?? MTPError.malformedData("could not append frame \(frame)")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? MTPError.malformedData("asset writer ended in state \(writer.status.rawValue)")
        }
    }

    /// Zeroes the movie header's creation and modification times, as many cameras do, so the
    /// file carries no creation date at all (`AVAsset.creationDate` is then nil).
    static func zeroMovieHeaderTimes(at url: URL) throws {
        var data = try Data(contentsOf: url)
        guard let tag = data.range(of: Data("mvhd".utf8)) else {
            throw MTPError.malformedData("no mvhd box in \(url.lastPathComponent)")
        }
        // version(1) flags(3), then creation_time and modification_time: 4 bytes each for
        // version 0, 8 bytes each for version 1.
        let width = data[tag.upperBound] == 1 ? 8 : 4
        let start = tag.upperBound + 4
        data.replaceSubrange(start ..< start + 2 * width, with: Data(repeating: 0, count: 2 * width))
        try data.write(to: url)
    }

    private static func makePixelBuffer(from adaptor: AVAssetWriterInputPixelBufferAdaptor, fill: UInt8) throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else {
            throw MTPError.malformedData("no pixel buffer pool")
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else {
            throw MTPError.malformedData("could not create a pixel buffer")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(fill), CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Track count and duration, the two things a passthrough re-mux must preserve.
    static func shape(of url: URL) async throws -> (tracks: Int, duration: CMTime) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks).count
        let duration = try await asset.load(.duration)
        return (tracks, duration)
    }
}
