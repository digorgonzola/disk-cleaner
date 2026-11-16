import Foundation

/// A release version, `major.minor.patch`. Pre-release suffixes are not supported because
/// releases are only ever tagged `vX.Y.Z` by release-please.
public struct Version: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// Accepts "1.2.3" or "v1.2.3"; anything else is nil.
    public init?(_ text: String) {
        let trimmed = text.hasPrefix("v") ? text.dropFirst() : Substring(text)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else { return nil }
            return Int(part)
        }
        guard numbers.count == 3 else { return nil }
        (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Version, rhs: Version) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public struct ReleaseInfo: Equatable, Sendable {
    public let version: Version
    /// The release page, with notes and the Gatekeeper instructions.
    public let pageURL: URL
    /// The app zip, when the release has one.
    public let downloadURL: URL?
    public let notes: String
}

public enum UpdateCheckError: LocalizedError, Equatable {
    case badStatus(Int)
    case invalidRelease(String)

    public var errorDescription: String? {
        switch self {
        case .badStatus(let status): "GitHub answered with HTTP \(status)"
        case .invalidRelease(let reason): "The latest release looks wrong: \(reason)"
        }
    }
}

/// Reads the latest GitHub release. Everything in the response is untrusted: the version
/// must be a plain `vX.Y.Z` tag, and the app only ever opens https links on github.com
/// under this repository's releases.
public enum UpdateChecker {
    public static let repository = "digorgonzola/disk-cleaner"
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static let releasesPathPrefix = "/\(repository)/releases/"

    /// - Throws: `UpdateCheckError` for a non-200 answer or a release that fails validation,
    ///   and `URLError` when the network request fails.
    public static func fetchLatest(appVersion: String, session: URLSession = .shared) async throws -> ReleaseInfo {
        var request = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // GitHub requires a User-Agent; it names the app only.
        request.setValue("DiskCleaner/\(appVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateCheckError.badStatus(status) }
        return try parse(data)
    }

    /// - Throws: `UpdateCheckError.invalidRelease` when the JSON is malformed, the release is
    ///   a draft or pre-release, the tag is not `vX.Y.Z`, or a link points outside the
    ///   repository's releases.
    public static func parse(_ data: Data) throws -> ReleaseInfo {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        struct Release: Decodable {
            let tag_name: String
            let html_url: String
            let draft: Bool
            let prerelease: Bool
            let body: String?
            let assets: [Asset]
        }

        let release: Release
        do {
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            throw UpdateCheckError.invalidRelease("unreadable response")
        }
        guard !release.draft, !release.prerelease else { throw UpdateCheckError.invalidRelease("draft or pre-release") }
        guard let version = Version(release.tag_name), release.tag_name.hasPrefix("v") else {
            throw UpdateCheckError.invalidRelease("tag \(release.tag_name.prefix(40)) is not vX.Y.Z")
        }
        guard let page = trustedURL(release.html_url) else { throw UpdateCheckError.invalidRelease("release page link") }

        let zipName = "DiskCleaner-\(version).zip"
        let download = release.assets.first { $0.name == zipName }.flatMap { trustedURL($0.browser_download_url) }
        return ReleaseInfo(version: version, pageURL: page, downloadURL: download, notes: release.body ?? "")
    }

    /// The URL, if it is https on github.com under this repository's releases.
    public static func trustedURL(_ text: String) -> URL? {
        guard let url = URL(string: text),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host == "github.com",
              components.user == nil, components.password == nil, components.port == nil,
              components.path.hasPrefix(releasesPathPrefix),
              !components.path.contains("/../")
        else { return nil }
        return url
    }

    /// True when `latest` is newer than the running version and not the one the user skipped.
    public static func isUpdate(_ latest: ReleaseInfo, current: Version, skipped: Version?) -> Bool {
        latest.version > current && latest.version != skipped
    }
}
