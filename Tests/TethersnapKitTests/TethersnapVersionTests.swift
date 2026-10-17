import Foundation
import Testing
@testable import TethersnapKit

@Suite("Version")
struct TethersnapVersionTests {
    @Test
    func `the CLI version matches the app bundle's CFBundleShortVersionString`() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TethersnapKitTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // package root
            .appendingPathComponent("Support/Info.plist")
        let data = try Data(contentsOf: plist)
        let info = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(info["CFBundleShortVersionString"] as? String == TethersnapVersion.current)
    }
}
