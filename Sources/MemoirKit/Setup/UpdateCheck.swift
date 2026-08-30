import Foundation

/// Asks whether a newer Memoir exists. Nothing else.
///
/// ## What this sends, exactly
///
/// One `GET` for a small static JSON file. **No query string, no headers identifying you, no
/// version of yours, no machine id, no account, because there is no account.** The comparison
/// happens here, on the version already in this binary, which is why the request carries
/// nothing about the person making it. A server logging these sees an IP asking for a file,
/// the same as loading a web page.
///
/// That distinction is the whole reason this is allowed to exist in a product whose privacy
/// document promises no telemetry: **telemetry reports on you, this asks a question.** The
/// difference has to survive contact with a sceptical reader, so it is stated here, in
/// `PRIVACY.md`, and in the Settings switch that turns it off.
///
/// It is counted like every other outbound request, at the send site, by the same
/// ``OutboundMonitor`` that counts the cloud brains. A check that quietly did not appear in
/// the count would make the count a lie.
///
/// ## What it deliberately does not do
///
/// It does not download, install, or replace anything. Self-updating a signed, notarised app
/// safely is a genuinely hard problem (it is the entire reason Sparkle exists), and Sparkle is
/// a third-party dependency this project does not have and does not want. So Memoir tells you,
/// and you decide. The cost is one manual download per update; the benefit is that nothing in
/// this app can ever replace its own binary.
public enum UpdateCheck {

    /// Where the manifest lives. A static file in the repository, not an API: no rate limit,
    /// no token, no JSON schema that can change underneath us.
    public static let manifestURL = URL(string:
        "https://raw.githubusercontent.com/Emanuelel/memoir/main/Packaging/latest.json")!

    /// What the manifest says.
    public struct Release: Sendable, Equatable, Codable {
        /// Dotted version, e.g. `0.2.0`.
        public let version: String
        /// Where a human goes to get it. Opened in the browser; never fetched by Memoir.
        public let url: URL
        /// One line for the band. Optional.
        public let notes: String?

        public init(version: String, url: URL, notes: String? = nil) {
            self.version = version
            self.url = url
            self.notes = notes
        }
    }

    /// The running version, read from the bundle so it can never drift from what was shipped.
    public static func currentVersion(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Fetches the manifest and returns a release **only when it is newer than this build**.
    ///
    /// Returns nil for every ordinary reason: no network, a malformed manifest, the same
    /// version, an older one. An update check that interrupts someone to report that it could
    /// not check is worse than one that says nothing.
    ///
    /// - Parameter session: injectable so the test suite never touches the network.
    public static func latest(
        current: String = currentVersion(),
        session: URLSession = .shared,
        url: URL = manifestURL
    ) async -> Release? {
        // Counted before the request goes out, not after it succeeds: a request that is made
        // and then fails still left the machine, and the counter has to mean that.
        OutboundMonitor.shared.record(destination: url.host ?? "update manifest")

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // No cache: an update check answered from a week-old cache is not an update check.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data)
        else { return nil }

        return isNewer(release.version, than: current) ? release : nil
    }

    /// Compares dotted version strings numerically, component by component.
    ///
    /// String comparison gets this wrong at exactly the moment it matters: "0.10.0" sorts
    /// before "0.9.0", so the tenth release would silently stop offering itself.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Numeric components, ignoring anything that is not a number so a `v` prefix or a
    /// `-beta.1` suffix cannot make a real version compare as zero.
    static func parts(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }
}
