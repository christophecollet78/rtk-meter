import Foundation

// MARK: - Data model

struct GainSummary: Decodable, Equatable {
    let totalCommands: Int
    let totalInput: Int
    let totalOutput: Int
    let totalSaved: Int
    let avgSavingsPct: Double
    let totalTimeMs: Int
    let avgTimeMs: Int

    enum CodingKeys: String, CodingKey {
        case totalCommands = "total_commands"
        case totalInput = "total_input"
        case totalOutput = "total_output"
        case totalSaved = "total_saved"
        case avgSavingsPct = "avg_savings_pct"
        case totalTimeMs = "total_time_ms"
        case avgTimeMs = "avg_time_ms"
    }
}

struct GainDay: Decodable, Equatable, Identifiable {
    let date: String
    let commands: Int
    let savedTokens: Int
    let savingsPct: Double

    var id: String { date }

    enum CodingKeys: String, CodingKey {
        case date
        case commands
        case savedTokens = "saved_tokens"
        case savingsPct = "savings_pct"
    }

    /// "2026-09-14" -> "14/09"
    var shortLabel: String {
        let parts = date.split(separator: "-")
        guard parts.count == 3 else { return date }
        return "\(parts[2])/\(parts[1])"
    }
}

struct GainPayload: Decodable {
    let summary: GainSummary
    let daily: [GainDay]?
}

struct TopCommand: Equatable, Identifiable {
    let name: String
    let count: Int
    /// Display string straight from rtk, e.g. "1.2M".
    let saved: String
    /// Same value as a number, so bars can be sized proportionally.
    let savedTokens: Double
    let pct: Double
    var id: String { name }
}

struct Stats: Equatable {
    let summary: GainSummary
    let daily: [GainDay]
    let top: [TopCommand]
}

// MARK: - Formatting

enum Fmt {
    static func compact(_ n: Int) -> String {
        let v = Double(n)
        switch abs(n) {
        case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 1_000...: return String(format: "%.1fK", v / 1_000)
        default: return "\(n)"
        }
    }

    static func duration(ms: Int) -> String {
        let s = ms / 1000
        if s >= 3600 { return "\(s / 3600)h\((s % 3600) / 60)m" }
        if s >= 60 { return "\(s / 60)m\(s % 60)s" }
        return "\(s)s"
    }

    static func pct(_ v: Double) -> String { String(format: "%.1f%%", v) }

    /// Block-element meter with 1/8 sub-cell resolution, for the status bar title.
    static func meter(pct: Double, cells: Int) -> String {
        let eighths = Int((min(max(pct, 0), 100) / 100 * Double(cells) * 8).rounded())
        return (0..<cells).map { i -> String in
            switch min(max(eighths - i * 8, 0), 8) {
            case 8: return "█"
            case 7: return "▉"
            case 6: return "▊"
            case 5: return "▋"
            case 4: return "▌"
            case 3: return "▍"
            case 2: return "▎"
            case 1: return "▏"
            default: return "·"
            }
        }.joined()
    }
}
