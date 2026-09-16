import AppKit
import SwiftUI

/// Renders the popover offscreen to a PNG so the UI can be reviewed in CI, in a
/// pull request, or over SSH — anywhere a screen capture is not available.
///
///     RTKMeter --render-preview out.png [rtk-gain-output.txt]
///
/// Set PREVIEW_UPDATE=1.2.0 to draw the update banner as well.
///
/// Materials and Liquid Glass only exist on screen, so PREVIEW_ONSCREEN=1 puts
/// the view in a real window over the desktop and screenshots that region
/// instead of drawing into an offscreen bitmap.
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

        let updater = Updater()
        if let version = ProcessInfo.processInfo.environment["PREVIEW_UPDATE"] {
            updater.setPreviewUpdate(version: version)
        }

        let detail = DetailView(store: store, settings: store.settings, updater: updater,
                                appearance: AppearanceMonitor())

        if ProcessInfo.processInfo.environment["PREVIEW_ONSCREEN"] == "1" {
            return renderOnScreen(detail: detail, to: path)
        }

        let view = NSHostingView(rootView: detail)
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

    /// Materials and Liquid Glass are composited by the window server, so they
    /// are invisible to an offscreen bitmap. This shows the view in a real
    /// window over a gradient — something for the glass to refract — and
    /// screenshots that window alone, never the surrounding screen.
    private static func renderOnScreen(detail: DetailView, to path: String) -> Int32 {
        let backdrop = LinearGradient(
            colors: [.orange, .purple, .blue, .teal],
            startPoint: .topLeading, endPoint: .bottomTrailing)

        let sized = NSHostingView(rootView: detail)
        let height = sized.fittingSize.height
        let root = NSHostingView(rootView: ZStack { backdrop; detail }
            .frame(width: 340, height: height))
        root.frame = NSRect(x: 0, y: 0, width: 340, height: height)
        root.layoutSubtreeIfNeeded()

        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.contentView = root
        window.center()
        window.orderFrontRegardless()

        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -l captures this window only, so nothing else on screen is recorded.
        capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", path]
        do { try capture.run() } catch { return 1 }
        capture.waitUntilExit()
        window.orderOut(nil)

        guard capture.terminationStatus == 0 else {
            FileHandle.standardError.write(Data("preview: screencapture failed\n".utf8))
            return 1
        }
        print("captured window 340x\(Int(height)) -> \(path)")
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
