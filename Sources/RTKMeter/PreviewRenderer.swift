import AppKit
import SwiftUI

/// Renders the popover offscreen to a PNG so the UI can be reviewed in CI, in a
/// pull request, or over SSH — anywhere a screen capture is not available.
///
///     RTKMeter --render-preview out.png [rtk-gain-output.txt]
enum PreviewRenderer {
    static func outputPath(from arguments: [String]) -> (png: String, fixture: String?)? {
        guard let flag = arguments.firstIndex(of: "--render-preview"),
              arguments.count > flag + 1 else { return nil }
        let png = arguments[flag + 1]
        let fixture = arguments.count > flag + 2 ? arguments[flag + 2] : nil
        return (png, fixture)
    }

    /// Exit code: 0 on success, 1 if the bitmap or the file could not be written.
    static func render(to path: String, fixture: String?) -> Int32 {
        let store = StatsStore(settings: AppSettings(defaults: scratchDefaults()))
        store.loadSample(topCommandsFrom: fixture)

        let view = NSHostingView(rootView: DetailView(store: store, settings: store.settings))
        view.frame = NSRect(x: 0, y: 0, width: 340, height: view.fittingSize.height)
        view.layoutSubtreeIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 1 }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("preview: \(error)\n".utf8))
            return 1
        }
        print("rendered \(Int(view.bounds.width))x\(Int(view.bounds.height)) -> \(path)")
        return 0
    }

    /// Never touch the user's real preferences while rendering.
    private static func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "local.rtkmeter.preview") ?? .standard
    }
}

extension StatsStore {
    /// Fills the store with representative numbers, plus real parsed rows when a
    /// captured `rtk gain` output is supplied.
    func loadSample(topCommandsFrom fixture: String?) {
        let text = fixture.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        setPreviewStats(Stats(
            summary: GainSummary(totalCommands: 5250, totalInput: 3_238_406,
                                 totalOutput: 1_894_261, totalSaved: 1_344_339,
                                 avgSavingsPct: 41.5, totalTimeMs: 595_448, avgTimeMs: 113),
            daily: (1...8).map { i in
                GainDay(date: String(format: "2026-09-%02d", i + 6), commands: 100 * i,
                        savedTokens: 20_000 * i, savingsPct: Double(18 + i * 4))
            },
            top: text.map(RTK.parseTopCommands) ?? PreviewFixtures.topCommands))
    }
}

enum PreviewFixtures {
    static let topCommands = [
        TopCommand(name: "rtk read", count: 255, saved: "1.2M", savedTokens: 1_200_000, pct: 4.5),
        TopCommand(name: "rtk grep", count: 653, saved: "93.2K", savedTokens: 93_200, pct: 26.4),
        TopCommand(name: "rtk git status", count: 42, saved: "18.4K",
                   savedTokens: 18_400, pct: 71.2),
        TopCommand(name: "rtk ls -la", count: 5, saved: "6.8K", savedTokens: 6_800, pct: 73.3),
        TopCommand(name: "rtk test", count: 18, saved: "5.1K", savedTokens: 5_100, pct: 64.0),
        TopCommand(name: "rtk tree src", count: 9, saved: "3.2K", savedTokens: 3_200, pct: 90.9),
    ]
}
