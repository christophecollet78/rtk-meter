import AppKit
import Foundation

/// A dotted version, compared numerically rather than as text.
struct SemanticVersion: Comparable, CustomStringConvertible, Equatable {
    let components: [Int]

    /// Accepts "1.2.3" and "v1.2.3"; returns nil for anything else.
    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop { $0 == "v" || $0 == "V" }
        let parts = trimmed.split(separator: ".").map { part in
            Int(part.prefix { $0.isNumber }) ?? -1
        }
        guard !parts.isEmpty, !parts.contains(-1) else { return nil }
        components = parts
    }

    /// The placeholder a local build carries when no tag is known.
    var isUnversioned: Bool { components.allSatisfy { $0 == 0 } }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }
}

struct ReleaseInfo: Equatable {
    let version: SemanticVersion
    let pageURL: URL
}

/// Checks the project's GitHub releases for a newer version, and runs
/// `brew upgrade` when the app was installed from the tap.
///
/// The repository and formula are read from Info.plist, so a fork only has to
/// pass `REPOSITORY` and `FORMULA` to build.sh.
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upgrading
        case upgraded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Set only when the release is newer than the running build.
    @Published private(set) var newer: ReleaseInfo?
    @Published private(set) var lastCheck: Date?

    let currentVersion: SemanticVersion
    private let repository: String
    private let formula: String
    private let session: URLSession

    private static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    init(bundle: Bundle = .main, session: URLSession = .shared) {
        let info = bundle.infoDictionary ?? [:]
        currentVersion =
            SemanticVersion(info["CFBundleShortVersionString"] as? String ?? "") ??
            SemanticVersion("0.0.0")!
        repository = info["UpdateRepository"] as? String ?? ""
        formula = info["HomebrewFormula"] as? String ?? ""
        self.session = session
    }

    /// True when this copy lives in a Homebrew Cellar, so `brew upgrade` applies.
    var isHomebrewManaged: Bool {
        !formula.isEmpty && Bundle.main.bundleURL.path.contains("/Cellar/")
    }

    var canCheck: Bool { !repository.isEmpty && !currentVersion.isUnversioned }

    // MARK: Checking

    func check() {
        guard canCheck, phase != .checking, phase != .upgrading else { return }
        guard let url = URL(string:
            "https://api.github.com/repos/\(repository)/releases/latest") else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        phase = .checking
        session.dataTask(with: request) { [weak self] data, _, _ in
            let release = data.flatMap(Self.parseRelease)
            DispatchQueue.main.async {
                guard let self else { return }
                self.phase = .idle
                self.lastCheck = Date()
                guard let release, release.version > self.currentVersion else {
                    self.newer = nil
                    return
                }
                self.newer = release
            }
        }.resume()
    }

    static func parseRelease(_ data: Data) -> ReleaseInfo? {
        struct Payload: Decodable {
            let tagName: String
            let htmlURL: String
            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case htmlURL = "html_url"
            }
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let version = SemanticVersion(payload.tagName),
              let url = URL(string: payload.htmlURL) else { return nil }
        return ReleaseInfo(version: version, pageURL: url)
    }

    // MARK: Upgrading

    func upgrade() {
        guard isHomebrewManaged, phase != .upgrading else { return }
        guard let brew = Self.brewPaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            phase = .failed("brew was not found")
            return
        }

        phase = .upgrading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.run(brew, ["upgrade", "--formula", self?.formula ?? ""])
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.phase = .upgraded
                case .failure(let failure):
                    self.phase = .failed(failure.message)
                }
            }
        }
    }

    /// Launches the upgraded bundle and quits this one; the Cellar path of a
    /// running copy still points at the old version, so relaunching via the
    /// stable `opt` symlink is what actually picks the update up.
    func relaunch() {
        let path = Self.optBundlePath() ?? Bundle.main.bundleURL.path
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-n", path]
        try? proc.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }

    /// "/opt/homebrew/Cellar/rtk-meter/1.0.3/X.app" -> "/opt/homebrew/opt/rtk-meter/X.app"
    private static func optBundlePath() -> String? {
        let url = Bundle.main.bundleURL
        let parts = url.pathComponents
        guard let cellar = parts.firstIndex(of: "Cellar"), parts.count > cellar + 2 else {
            return nil
        }
        let prefix = parts[..<cellar].joined(separator: "/")
        let candidate = "\(prefix)/opt/\(parts[cellar + 1])/\(url.lastPathComponent)"
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    /// Injects a pending release; used by the offscreen preview renderer only.
    func setPreviewUpdate(version: String, phase: Phase = .idle) {
        newer = SemanticVersion(version).map {
            ReleaseInfo(version: $0,
                        pageURL: URL(string: "https://example.invalid/releases")!)
        }
        self.phase = phase
    }

    func openReleasePage() {
        guard let url = newer?.pageURL else { return }
        NSWorkspace.shared.open(url)
    }

    private struct CommandFailure: Error {
        let message: String
    }

    private static func run(_ path: String, _ args: [String]) -> Result<Void, CommandFailure> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        var output = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        do { try proc.run() } catch { return .failure(CommandFailure(message: "could not run brew")) }

        // An upgrade downloads a release asset; allow for a slow connection.
        if done.wait(timeout: .now() + 300) == .timedOut {
            proc.terminate()
            return .failure(CommandFailure(message: "brew upgrade timed out"))
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let text = String(data: output, encoding: .utf8) ?? ""
            let lastLine = text.split(separator: "\n").last { !$0.isEmpty }
            return .failure(CommandFailure(
                message: lastLine.map(String.init) ?? "brew upgrade failed"))
        }
        return .success(())
    }
}
