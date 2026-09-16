import AppKit
import SwiftUI

/// Tracks the accessibility display settings that decide whether the popover may
/// use translucency, and republishes them when the user changes them.
final class AppearanceMonitor: ObservableObject {
    @Published private(set) var reduceTransparency: Bool
    @Published private(set) var increaseContrast: Bool
    @Published private(set) var reduceMotion: Bool
    /// The system Liquid Glass tint slider (Appearance settings), 0 = clear,
    /// 1 = fully tinted. Absent before macOS 26, where 0.5 is a fair neutral.
    @Published private(set) var glassTint: Double

    /// Preferences written by System Settings reach us lazily, so the value is
    /// re-read whenever the popover is about to be shown.
    func refreshFromSystem() {
        let value = Self.readGlassTint()
        if value != glassTint {
            Self.log("glass tint \(glassTint) -> \(value)")
            glassTint = value
        } else {
            Self.log("glass tint unchanged at \(value)")
        }
    }

    /// RTKMETER_DIAGNOSTICS=1 logs what the app reads, for debugging a setting
    /// that appears not to apply.
    static let isDiagnostic = ProcessInfo.processInfo.environment["RTKMETER_DIAGNOSTICS"] == "1"

    /// Unbuffered, so the log is readable while the app is still running.
    static func log(_ message: String) {
        guard isDiagnostic else { return }
        FileHandle.standardError.write(Data("appearance: \(message)\n".utf8))
    }

    var summary: String {
        """
        glassTint          \(glassTint)
        reduceTransparency \(reduceTransparency)
        increaseContrast   \(increaseContrast)
        reduceMotion       \(reduceMotion)
        """
    }

    private static func readGlassTint() -> Double {
        if let override = ProcessInfo.processInfo.environment["PREVIEW_GLASS_TINT"],
           let value = Double(override) {
            return min(max(value, 0), 1)
        }
        // Read through CFPreferences after a sync: UserDefaults caches other
        // domains for the life of the process, so a slider moved in System
        // Settings would otherwise never reach a long-running agent.
        // CFPreferencesSynchronize, not CFPreferencesAppSynchronize: the value
        // lives in the global domain, and only the three-argument form drops the
        // cached copy a long-running process would otherwise keep forever.
        CFPreferencesSynchronize(kCFPreferencesAnyApplication,
                                 kCFPreferencesCurrentUser,
                                 kCFPreferencesAnyHost)
        let raw = CFPreferencesCopyValue("NSGlassTintAmount" as CFString,
                                         kCFPreferencesAnyApplication,
                                         kCFPreferencesCurrentUser,
                                         kCFPreferencesAnyHost)
        guard let stored = (raw as? NSNumber)?.doubleValue else { return 0.5 }
        return min(max(stored, 0), 1)
    }

    private var pollTimer: Timer?

    init() {
        let workspace = NSWorkspace.shared
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        glassTint = Self.readGlassTint()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(optionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)

        if Self.isDiagnostic { startLiveUpdates() }
    }

    /// There is no notification for the Appearance slider, so while the panel is
    /// on screen the value is polled: moving the slider then changes the panel
    /// under the cursor instead of only on the next open.
    func startLiveUpdates() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshFromSystem()
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stopLiveUpdates() {
        guard !Self.isDiagnostic else { return }
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @objc private func optionsChanged() {
        let workspace = NSWorkspace.shared
        DispatchQueue.main.async {
            self.reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
            self.increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
            self.reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
            self.glassTint = Self.readGlassTint()
        }
    }
}

/// An AppKit material, for the macOS versions that predate Liquid Glass.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.isEmphasized = emphasized
    }
}

/// How a panel should be drawn, given the system settings and the user's own
/// preference. Resolved once per render so every panel agrees.
enum PanelStyle: Equatable {
    /// Liquid Glass, macOS 26 and later, carrying the system tint amount so the
    /// panels follow the Appearance slider instead of pinning one look.
    case glass(tint: Double)
    /// A vibrant material: the same intent on older systems.
    case material
    /// Opaque fills, for Reduce Transparency.
    case solid

    static func resolve(monitor: AppearanceMonitor, enabled: Bool) -> PanelStyle {
        guard enabled, !monitor.reduceTransparency else { return .solid }
        if #available(macOS 26.0, *) { return .glass(tint: monitor.glassTint) }
        return .material
    }
}

/// The window's own background. This is what the system transparency settings
/// act on, so it is Liquid Glass where that exists, a material before it, and an
/// opaque fill when transparency is reduced.
struct PanelBackdrop: View {
    let style: PanelStyle

    var body: some View {
        switch style {
        case .glass(let tint):
            if #available(macOS 26.0, *) {
                ZStack {
                    Color.clear.glassEffect(tint < 0.5 ? .clear : .regular, in: Rectangle())
                    // Clear glass alone barely differs from tinted at window
                    // size, so the slider also drives an explicit fill: fully
                    // see-through at 0, nearly solid at 1.
                    Color(nsColor: .windowBackgroundColor).opacity(0.75 * tint)
                }
            } else {
                VisualEffectBackground(material: .popover, blending: .behindWindow)
            }
        case .material:
            VisualEffectBackground(material: .popover, blending: .behindWindow)
        case .solid:
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

extension View {
    /// Draws the receiver as a panel: Liquid Glass where available, a vibrant
    /// material before that, and a plain fill whenever the system asks for
    /// reduced transparency.
    @ViewBuilder
    func panelBackground(_ style: PanelStyle, cornerRadius: CGFloat = 12,
                         bordered: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch style {
        case .glass(let tint):
            if #available(macOS 26.0, *) {
                // Below the midpoint the slider asks for clear glass, above it
                // for tinted; the fill underneath tracks the whole range, so
                // moving the slider changes the panels rather than only their
                // edges. At 0 the panel is pure glass, at 1 it is nearly solid.
                let base: Glass = tint < 0.5 ? .clear : .regular
                background(Color(nsColor: .controlBackgroundColor).opacity(0.55 * tint),
                           in: shape)
                    .glassEffect(base, in: shape)
                    .overlay { if bordered { shape.strokeBorder(.separator, lineWidth: 1) } }
            } else {
                self
            }
        case .material:
            background {
                VisualEffectBackground(material: .hudWindow, blending: .withinWindow)
                    .clipShape(shape)
            }
            .overlay { if bordered { shape.strokeBorder(.separator, lineWidth: 1) } }
        case .solid:
            background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay { if bordered { shape.strokeBorder(.separator, lineWidth: 1) } }
        }
    }

    /// Groups sibling panels so their glass can merge, on the systems that do that.
    @ViewBuilder
    func panelGroup(_ style: PanelStyle, spacing: CGFloat = 12) -> some View {
        if case .glass = style, #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}
