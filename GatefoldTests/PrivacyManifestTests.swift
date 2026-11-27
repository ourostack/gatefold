import Foundation
import Testing
@testable import Gatefold

/// App Store Connect refuses a build whose bundle has no privacy manifest (ITMS-91053). The manifest's contents are
/// checked against the code on Linux (scripts/store-readiness.py); this checks the built app really carries it.
struct PrivacyManifestTests {
    private func manifest() throws -> [String: Any] {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
                               "the app bundle has no PrivacyInfo.xcprivacy")
        let data = try Data(contentsOf: url)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func theAppShipsItsPrivacyManifest() throws {
        let plist = try manifest()
        #expect(plist["NSPrivacyTracking"] as? Bool == false)
    }

    @Test func itDeclaresTheRequiredReasonAPIsTheAppCalls() throws {
        let types = try #require(try manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let declared = Set(types.compactMap { $0["NSPrivacyAccessedAPIType"] as? String })
        #expect(declared.isSuperset(of: ["NSPrivacyAccessedAPICategoryUserDefaults",
                                         "NSPrivacyAccessedAPICategoryFileTimestamp"]))
    }

    /// Release builds send counts-only telemetry, so the manifest must say what goes out, none of it linked or tracking.
    @Test func itDeclaresWhatTheTelemetrySends() throws {
        let kinds = try #require(try manifest()["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        #expect(Set(kinds.compactMap { $0["NSPrivacyCollectedDataType"] as? String }) == [
            "NSPrivacyCollectedDataTypeOtherDiagnosticData",
            "NSPrivacyCollectedDataTypeProductInteraction",
            "NSPrivacyCollectedDataTypeDeviceID",
        ])
        for kind in kinds {
            #expect(kind["NSPrivacyCollectedDataTypeLinked"] as? Bool == false)
            #expect(kind["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
        }
    }
}
