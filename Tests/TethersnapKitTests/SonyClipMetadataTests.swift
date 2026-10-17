import Foundation
import Testing
@testable import TethersnapKit

@Suite("Sony clip metadata")
struct SonyClipMetadataTests {
    /// The shape of a Sony NonRealTimeMeta record, with made-up values.
    static let record = """
    <?xml version="1.0" encoding="UTF-8"?>
    <NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.00" lastUpdate="2026-08-30T12:34:56-07:00">
    \t<TargetMaterial umidRef="060A2B340101010501010D4313000000000000000000000000000000000000000"/>
    \t<Duration value="600"/>
    \t<CreationDate value="2026-08-30T12:34:56-07:00"/>
    \t<Device manufacturer="Sony" modelName="ILCE-7M3" serialNo="4294967295"/>
    </NonRealTimeMeta>
    """

    /// The same record with the `ExifGPS` group a linked phone fills in.
    static let locatedRecord = record.replacingOccurrences(of: "</NonRealTimeMeta>", with: """
    \t<AcquisitionRecord>
    \t\t<Group name="CameraUnitMetadataSet">
    \t\t\t<Item name="CaptureGammaEquation" value="rec709-xvycc"/>
    \t\t</Group>
    \t\t<Group name="ExifGPS">
    \t\t\t<Item name="VersionID" value="2.2.0.0"/>
    \t\t\t<Item name="LatitudeRef" value="N"/>
    \t\t\t<Item name="Latitude" value="37:24:56.169"/>
    \t\t\t<Item name="LongitudeRef" value="W"/>
    \t\t\t<Item name="Longitude" value="121:57:28.318"/>
    \t\t\t<Item name="Status" value="A"/>
    \t\t\t<Item name="MapDatum" value="WGS-84"/>
    \t\t</Group>
    \t</AcquisitionRecord>
    </NonRealTimeMeta>
    """)

    @Test
    func `The record yields the start time in its zone and the camera`() throws {
        let record = try #require(SonyClipMetadata.parse(Data(Self.record.utf8)))

        #expect(record.creationDate == MovieMetadataPatcherTests.date)
        #expect(record.timeZone.secondsFromGMT() == -7 * 3600)
        #expect(record.manufacturer == "Sony")
        #expect(record.model == "ILCE-7M3")
        #expect(record.hasCamera)
        #expect(record.location == nil)
    }

    @Test
    func `A fix in the ExifGPS group becomes signed decimal degrees, a void one nothing`() throws {
        let located = try #require(SonyClipMetadata.parse(Data(Self.locatedRecord.utf8)))
        let location = try #require(located.location)

        #expect(abs(location.latitude - 37.415_602_5) < 0.000_001)
        #expect(abs(location.longitude - -121.957_866) < 0.000_001)
        #expect(MovieMetadataPatcher.iso6709(location) == "+37.4156-121.9579/")
        #expect(MovieMetadataPatcher.iso6709(.init(latitude: -1.5, longitude: 4.25)) == "-01.5000+004.2500/")
        let void = Self.locatedRecord.replacingOccurrences(of: "value=\"A\"", with: "value=\"V\"")
        #expect(SonyClipMetadata.parse(Data(void.utf8))?.location == nil)
        #expect(SonyClipMetadata.location(from: ["Latitude": "91:00:00", "LatitudeRef": "N", "Longitude": "0:0:0", "LongitudeRef": "E"]) == nil)
        #expect(SonyClipMetadata.location(from: ["Latitude": "37:24:56.169", "LatitudeRef": "N"]) == nil)
    }

    @Test
    func `Other documents and records without a date are rejected`() {
        #expect(SonyClipMetadata.parse(Data("<Other><CreationDate value=\"2026-08-30T12:34:56-07:00\"/></Other>".utf8)) == nil)
        #expect(SonyClipMetadata.parse(Data("<NonRealTimeMeta><Device manufacturer=\"Sony\"/></NonRealTimeMeta>".utf8)) == nil)
        #expect(SonyClipMetadata.parse(Data("not xml".utf8)) == nil)
        let bare = SonyClipMetadata.parse(Data("<NonRealTimeMeta><CreationDate value=\"2026-08-30T12:34:56Z\"/></NonRealTimeMeta>".utf8))
        #expect(bare?.hasCamera == false)
        #expect(bare?.timeZone.secondsFromGMT() == 0)
    }

    @Test
    func `The sidecar beside a clip is read, and its name is never a candidate`() throws {
        let directory = try ImageDateWriterTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = directory.appendingPathComponent("C0001.MP4")
        try Data("no boxes".utf8).write(to: clip)
        try Data(Self.record.utf8).write(to: directory.appendingPathComponent("C0001M01.XML"))

        #expect(SonyClipMetadata.read(for: clip)?.model == "ILCE-7M3")
        #expect(SonyClipMetadata.read(for: directory.appendingPathComponent("C0002.MP4")) == nil)
        #expect(SonyClipMetadata.isSidecarName("C0001M01.XML"))
        #expect(SonyClipMetadata.isSidecarName("c0001m01.xml"))
        #expect(!SonyClipMetadata.isSidecarName("C0001.MP4"))
        #expect(!SonyClipMetadata.isSidecarName("M01.XML"))
    }

    @Test
    func `The copy inside the clip wins over the sidecar`() throws {
        let directory = try ImageDateWriterTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = directory.appendingPathComponent("C0001.MP4")
        try MovieMetadataPatcherTests.syntheticMovie(moovFirst: false, headerVersion: 0, xml: Data(Self.record.utf8)).write(to: clip)
        let other = Self.record.replacingOccurrences(of: "ILCE-7M3", with: "ILCE-1")
        try Data(other.utf8).write(to: directory.appendingPathComponent("C0001M01.XML"))

        #expect(SonyClipMetadata.read(for: clip)?.model == "ILCE-7M3")
    }
}
