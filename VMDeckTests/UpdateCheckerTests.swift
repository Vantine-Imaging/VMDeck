import Foundation
import Testing
@testable import VMDeck

@Suite struct UpdateCheckerTests {
    @Test func comparesVersions() {
        #expect(AppRelease.isNewer("1.3.1", than: "1.3.0"))
        #expect(AppRelease.isNewer("v1.4", than: "1.3.9"))
        #expect(AppRelease.isNewer("2.0.0", than: "1.99.99"))
        #expect(!AppRelease.isNewer("1.3.1", than: "1.3.1"))
        #expect(!AppRelease.isNewer("1.3", than: "1.3.0"))
        #expect(!AppRelease.isNewer("1.2.9", than: "1.3.0"))
    }

    @Test func parsesGitHubRelease() throws {
        let json = """
        {"tag_name":"v1.3.1","name":"VMDeck 1.3.1","body":"## Notes\\n- one","html_url":"https://github.com/Vantine-Imaging/VMDeck/releases/tag/v1.3.1",
         "draft":false,"prerelease":false,
         "assets":[{"name":"VMDeck-1.3.1.pkg","browser_download_url":"https://github.com/Vantine-Imaging/VMDeck/releases/download/v1.3.1/VMDeck-1.3.1.pkg"}]}
        """
        let r = try AppRelease.parse(Data(json.utf8))
        #expect(r.version == "1.3.1" && r.tag == "v1.3.1")
        #expect(r.installerURL?.lastPathComponent == "VMDeck-1.3.1.pkg")
        #expect(r.notes.hasPrefix("## Notes"))
    }

    @Test @MainActor func skippedVersionStaysQuietButManualCheckShowsIt() async throws {
        let defaults = try #require(UserDefaults(suiteName: "vmdeck-tests-\(UUID().uuidString)"))
        let checker = UpdateChecker(defaults: defaults, currentVersion: "1.0.0")
        let release = AppRelease(version: "1.3.1", tag: "v1.3.1", notes: "", pageURL: URL(string: "https://example.com")!)
        checker.skip(release)
        #expect(defaults.string(forKey: UpdateChecker.skippedKey) == "1.3.1")
        #expect(checker.available == nil)
    }
}

/// Serves canned GitHub answers to the checker.
final class StubReleaseProtocol: URLProtocol {
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.github.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct UpdateCheckerNetworkTests {
    @MainActor private func makeChecker(version: String) throws -> (UpdateChecker, UserDefaults) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubReleaseProtocol.self]
        let defaults = try #require(UserDefaults(suiteName: "vmdeck-update-\(UUID().uuidString)"))
        return (UpdateChecker(session: URLSession(configuration: config), defaults: defaults, currentVersion: version), defaults)
    }

    @Test @MainActor func offersANewerReleaseAndRecordsTheCheck() async throws {
        StubReleaseProtocol.status = 200
        StubReleaseProtocol.body = #"{"tag_name":"v9.9.0","body":"big","html_url":"https://github.com/x/y/releases/tag/v9.9.0","draft":false,"prerelease":false,"assets":[]}"#
        let (checker, defaults) = try makeChecker(version: "1.3.1")
        await checker.checkIfDue()
        #expect(checker.available?.version == "9.9.0")
        #expect(defaults.object(forKey: UpdateChecker.lastCheckKey) is Date)
        // A second automatic check within a day does nothing.
        checker.available = nil
        await checker.checkIfDue()
        #expect(checker.available == nil)
        // Skipped versions stay quiet automatically but show on a manual check.
        checker.skip(AppRelease(version: "9.9.0", tag: "v9.9.0", notes: "", pageURL: URL(string: "https://x")!))
        await checker.check(manual: false)
        #expect(checker.available == nil)
        await checker.check(manual: true)
        #expect(checker.available?.version == "9.9.0")
    }

    @Test @MainActor func upToDateAndErrorsOnlySpeakWhenAsked() async throws {
        StubReleaseProtocol.status = 200
        StubReleaseProtocol.body = #"{"tag_name":"v1.3.1","html_url":"https://github.com/x/y","draft":false,"prerelease":false,"assets":[]}"#
        let (checker, _) = try makeChecker(version: "1.3.1")
        await checker.check(manual: false)
        #expect(checker.available == nil && checker.manualResult == nil)
        await checker.check(manual: true)
        #expect(checker.manualResult?.contains("latest") == true)
        StubReleaseProtocol.status = 503
        await checker.check(manual: true)
        #expect(checker.manualResult?.hasPrefix("Couldn't check") == true)
    }
}
