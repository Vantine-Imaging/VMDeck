import Foundation
import Observation

/// A published release on GitHub.
struct AppRelease: Equatable, Sendable, Identifiable {
    var version: String
    var tag: String
    var notes: String
    /// The release page.
    var pageURL: URL
    /// The installer attached to the release, when there is one.
    var installerURL: URL?
    var id: String { tag }

    /// "v1.3.1" → [1, 3, 1]. Missing parts count as 0.
    static func components(_ version: String) -> [Int] {
        var v = version.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        return v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// True when `a` is a newer version than `b`.
    static func isNewer(_ a: String, than b: String) -> Bool {
        var x = components(a), y = components(b)
        while x.count < y.count { x.append(0) }
        while y.count < x.count { y.append(0) }
        return x.lexicographicallyPrecedes(y) == false && x != y
    }

    /// Parses GitHub's `releases/latest` JSON.
    static func parse(_ data: Data) throws -> AppRelease {
        struct Payload: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String
            let name: String?
            let body: String?
            let html_url: URL
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]
        }
        let p = try JSONDecoder().decode(Payload.self, from: data)
        let pkg = p.assets.first { $0.name.hasSuffix(".pkg") }?.browser_download_url
        var version = p.tag_name
        if version.hasPrefix("v") { version.removeFirst() }
        return AppRelease(version: version, tag: p.tag_name, notes: p.body ?? "", pageURL: p.html_url, installerURL: pkg)
    }
}

/// Asks GitHub for the latest release and compares it with the running app.
/// Checks once a day on launch, or whenever the user asks.
@MainActor
@Observable
final class UpdateChecker {
    static let repo = "Vantine-Imaging/VMDeck"
    static let latestURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    static let lastCheckKey = "updateLastCheck"
    static let skippedKey = "updateSkippedVersion"
    static let interval: TimeInterval = 24 * 3600

    /// A newer release the user hasn't skipped; drives the update sheet.
    var available: AppRelease?
    /// Set after a manual check that found nothing newer, or that failed.
    var manualResult: String?
    private(set) var checking = false

    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let defaults: UserDefaults
    let currentVersion: String

    init(session: URLSession = .shared, defaults: UserDefaults = .standard,
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") {
        self.session = session
        self.defaults = defaults
        self.currentVersion = currentVersion
    }

    /// The daily check. Quiet: shows the sheet only when something is newer.
    func checkIfDue() async {
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(last) >= Self.interval else { return }
        await check(manual: false)
    }

    func check(manual: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        manualResult = nil
        do {
            let release = try await fetchLatest()
            defaults.set(Date.now, forKey: Self.lastCheckKey)
            if AppRelease.isNewer(release.version, than: currentVersion) {
                let skipped = defaults.string(forKey: Self.skippedKey)
                if manual || skipped != release.version {
                    available = release
                }
            } else if manual {
                manualResult = "VMDeck \(currentVersion) is the latest version."
            }
        } catch {
            if manual { manualResult = "Couldn't check for updates: \(error.localizedDescription)" }
        }
    }

    func skip(_ release: AppRelease) {
        defaults.set(release.version, forKey: Self.skippedKey)
        available = nil
    }

    private func fetchLatest() async throws -> AppRelease {
        var request = URLRequest(url: Self.latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("VMDeck/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "GitHub answered \(http.statusCode)."])
        }
        return try AppRelease.parse(data)
    }
}
