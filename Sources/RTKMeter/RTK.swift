import Foundation

enum RTKError: Error, Equatable {
    case notFound
    case failed(String)
    case timedOut
    case badJSON

    var message: String {
        switch self {
        case .notFound:
            return "rtk was not found. Install it, or set a path in the popover settings."
        case .failed(let why):
            return why.isEmpty ? "rtk gain exited with an error" : why
        case .timedOut:
            return "rtk gain timed out"
        case .badJSON:
            return "unexpected rtk gain output"
        }
    }
}

/// Runs the `rtk` CLI and turns its output into `Stats`.
enum RTK {
    /// A GUI app does not inherit the login shell PATH, so probe the usual install
    /// sites before paying for a login shell.
    static let candidatePaths = [
        "/opt/homebrew/bin/rtk",
        "/usr/local/bin/rtk",
        "\(NSHomeDirectory())/.cargo/bin/rtk",
        "\(NSHomeDirectory())/.local/bin/rtk",
    ]

    /// Seconds before a stuck `rtk` invocation is given up on and killed.
    static var timeout: TimeInterval = 15

    private static var discovered: String?

    /// - Parameter override: an explicit binary path from settings; empty means discover.
    static func resolveBinary(override: String = "") -> String? {
        let fm = FileManager.default
        let trimmed = override.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            return fm.isExecutableFile(atPath: trimmed) ? trimmed : nil
        }
        if let discovered, fm.isExecutableFile(atPath: discovered) { return discovered }
        for path in candidatePaths where fm.isExecutableFile(atPath: path) {
            discovered = path
            return path
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let out = run(shell, ["-lc", "command -v rtk"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !out.isEmpty, fm.isExecutableFile(atPath: out) {
            discovered = out
            return out
        }
        return nil
    }

    /// Runs a command and returns stdout, or nil on non-zero exit, spawn failure or timeout.
    private static func run(_ launchPath: String, _ args: [String],
                            workingDirectory: String? = nil) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        if let workingDirectory, !workingDirectory.isEmpty {
            proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        // Plain, stable output: no colour escapes, no pager, fixed table width.
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env["COLUMNS"] = "120"
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        // Drain the pipe on another queue: a process that outfills the pipe buffer
        // would otherwise block forever while we wait for it to exit.
        let box = OutputBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }

        do { try proc.run() } catch { return nil }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: box.data, encoding: .utf8)
    }

    private final class OutputBox: @unchecked Sendable {
        var data = Data()
    }

    static func fetch(binaryOverride: String = "", projectScope: String = "")
        -> Result<Stats, RTKError> {
        guard let bin = resolveBinary(override: binaryOverride) else { return .failure(.notFound) }
        // `rtk gain --project` scopes to the working directory, so run it from there.
        let scopeArgs = projectScope.isEmpty ? [] : ["--project"]
        let cwd = projectScope.isEmpty ? nil : projectScope

        guard let json = run(bin, ["gain", "-f", "json", "-d"] + scopeArgs, workingDirectory: cwd)
        else { return .failure(.failed("rtk gain failed or timed out")) }
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(GainPayload.self, from: data)
        else { return .failure(.badJSON) }

        // The per-command breakdown exists only in the text renderer; treat it as a bonus.
        let top = run(bin, ["gain"] + scopeArgs, workingDirectory: cwd).map(parseTopCommands) ?? []
        return .success(Stats(summary: payload.summary, daily: payload.daily ?? [], top: top))
    }

    /// "93.2K" -> 93200
    static func expand(_ s: String) -> Double {
        let multipliers: [Character: Double] = ["K": 1_000, "M": 1_000_000, "B": 1_000_000_000]
        if let last = s.last, let mult = multipliers[last] {
            return (Double(s.dropLast()) ?? 0) * mult
        }
        return Double(s) ?? 0
    }

    /// Parses rows of the "By Command" table, e.g.
    /// ` 1.  rtk grep                    653  93.2K   26.4%    25ms  █░░░░░░░░░`
    static func parseTopCommands(_ text: String) -> [TopCommand] {
        let pattern = #"^\s*\d+\.\s+(\S.*?)\s{2,}(\d+)\s+([\d.]+[KMB]?)\s+([\d.]+)%"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { m in
                guard m.numberOfRanges == 5,
                      let count = Int(ns.substring(with: m.range(at: 2))),
                      let pct = Double(ns.substring(with: m.range(at: 4)))
                else { return nil }
                let saved = ns.substring(with: m.range(at: 3))
                return TopCommand(
                    name: ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces),
                    count: count, saved: saved, savedTokens: expand(saved), pct: pct)
            }
    }
}
