import Foundation

public struct SemanticVersion: Equatable, Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init?(parsing raw: String) {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("v") || cleaned.hasPrefix("V") {
            cleaned.removeFirst()
        }
        let buildSplit = cleaned.split(separator: "+", maxSplits: 1)
        let coreAndPre = String(buildSplit[0])
        let preSplit = coreAndPre.split(separator: "-", maxSplits: 1)
        let numericParts = preSplit[0].split(separator: ".")
        guard numericParts.count >= 2,
              let maj = Int(numericParts[0]),
              let min = Int(numericParts[1]) else {
            return nil
        }
        let pat = numericParts.count >= 3 ? (Int(numericParts[2]) ?? 0) : 0
        self.major = maj
        self.minor = min
        self.patch = pat
        self.prerelease = preSplit.count > 1 ? String(preSplit[1]) : nil
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, .some): return false
        case (.some, nil): return true
        case (.some(let l), .some(let r)): return l < r
        }
    }
}

public struct ReleaseUpdateInfo: Equatable, Sendable {
    public var version: String
    public var tagName: String
    public var releaseURL: URL
    public var summary: String
    public var publishedAt: String?

    public init(version: String, tagName: String, releaseURL: URL, summary: String, publishedAt: String? = nil) {
        self.version = version
        self.tagName = tagName
        self.releaseURL = releaseURL
        self.summary = summary
        self.publishedAt = publishedAt
    }
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(currentVersion: String)
    case updateAvailable(currentVersion: String, release: ReleaseUpdateInfo)
    case noPublishedRelease(currentVersion: String)
    case failed(String)
}

public enum UpdateCheckService {
    public static let defaultLatestReleaseAPIURL = URL(string: "https://api.github.com/repos/Profeel/autoroute/releases/latest")!
    public static let defaultFallbackVersion = "0.1.0"

    public static func currentAppVersion(bundle: Bundle = .main) -> String {
        if let v = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
           !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return defaultFallbackVersion
    }

    public static func checkForUpdates(
        currentVersion: String? = nil,
        endpointURL: URL = defaultLatestReleaseAPIURL,
        session: URLSession = .shared
    ) async -> UpdateCheckResult {
        let localVersionStr = currentVersion ?? currentAppVersion()
        var request = URLRequest(url: endpointURL)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AutoRoute/\(localVersionStr)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("更新检查未收到有效 HTTP 响应。")
            }
            if http.statusCode == 404 {
                return .noPublishedRelease(currentVersion: localVersionStr)
            }
            guard (200...299).contains(http.statusCode) else {
                return .failed("更新检查失败 (HTTP \(http.statusCode))。")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  !tagName.isEmpty else {
                return .failed("无法解析远程 Release 版本信息。")
            }
            let htmlURLStr = (json["html_url"] as? String) ?? "https://github.com/Profeel/autoroute/releases"
            guard let releaseURL = URL(string: htmlURLStr) else {
                return .failed("远程 Release 链接格式无效。")
            }
            let body = (json["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let summary = String(body.prefix(240))
            let publishedAt = json["published_at"] as? String
            let remoteVersionStr = tagName.hasPrefix("v") || tagName.hasPrefix("V")
                ? String(tagName.dropFirst())
                : tagName

            if let localSemver = SemanticVersion(parsing: localVersionStr),
               let remoteSemver = SemanticVersion(parsing: remoteVersionStr) {
                if remoteSemver > localSemver {
                    return .updateAvailable(
                        currentVersion: localVersionStr,
                        release: ReleaseUpdateInfo(
                            version: remoteVersionStr,
                            tagName: tagName,
                            releaseURL: releaseURL,
                            summary: summary,
                            publishedAt: publishedAt
                        )
                    )
                }
                return .upToDate(currentVersion: localVersionStr)
            }

            if remoteVersionStr != localVersionStr {
                return .updateAvailable(
                    currentVersion: localVersionStr,
                    release: ReleaseUpdateInfo(
                        version: remoteVersionStr,
                        tagName: tagName,
                        releaseURL: releaseURL,
                        summary: summary,
                        publishedAt: publishedAt
                    )
                )
            }
            return .upToDate(currentVersion: localVersionStr)
        } catch {
            return .failed("网络请求失败：\(error.localizedDescription)")
        }
    }
}
