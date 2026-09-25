import SwiftUI

/// Fetches stats off the main thread and publishes them to the popover and status item.
final class StatsStore: ObservableObject {
    @Published private(set) var stats: Stats?
    @Published private(set) var error: RTKError?
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var isLoading = false
    /// Set only once a fetch has been running long enough to be worth showing,
    /// so a fast refresh does not blink a spinner on every popover open.
    @Published private(set) var showsProgress = false

    let settings: AppSettings
    private let queue = DispatchQueue(label: "rtkmeter.fetch", qos: .utility)

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    /// Injects fixed values; used by the offscreen preview renderer, never by the app.
    func setPreviewStats(_ stats: Stats) {
        self.stats = stats
        self.lastUpdate = Date()
    }

    /// How long a fetch must run before the spinner appears.
    private let progressDelay: TimeInterval = 0.3

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        DispatchQueue.main.asyncAfter(deadline: .now() + progressDelay) { [weak self] in
            guard let self, self.isLoading else { return }
            self.showsProgress = true
        }
        let override = settings.rtkPath
        let scope = settings.projectScope
        queue.async { [weak self] in
            let result = RTK.fetch(binaryOverride: override, projectScope: scope)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                self.showsProgress = false
                switch result {
                case .success(let s):
                    self.stats = s
                    self.error = nil
                    self.lastUpdate = Date()
                case .failure(let e):
                    self.error = e
                }
            }
        }
    }
}

// MARK: - Popover

struct DetailView: View {
    @ObservedObject var store: StatsStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var updater: Updater
    @ObservedObject var appearance: AppearanceMonitor

    private var panelStyle: PanelStyle {
        PanelStyle.resolve(monitor: appearance, enabled: settings.useGlass)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            updateBanner
            content
            Divider()
            footer
        }
        .frame(width: 340)
        .background { PanelBackdrop(style: panelStyle) }
        .clipShape(RoundedRectangle(cornerRadius: PanelStyle.cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        if let stats = store.stats {
            // No ScrollView: every section has a bounded height, so the popover
            // shows the whole report at once and sizes itself to fit.
            VStack(alignment: .leading, spacing: 10) {
                panel { gauge(stats.summary) }
                panel { statGrid(stats.summary) }
                if !stats.daily.isEmpty { panel { dailyChart(stats.daily) } }
                if !stats.top.isEmpty { panel { topCommands(stats.top) } }
            }
            .padding(12)
            .panelGroup(panelStyle, spacing: 10)
        } else if let error = store.error {
            errorBlock(error)
        } else {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity).padding(40)
        }
    }

    @ViewBuilder
    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if panelStyle.usesSectionPanels {
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelBackground(panelStyle, bordered: appearance.increaseContrast)
        } else {
            // One sheet of glass: the sections are spaced, not boxed.
            content()
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(.tint)
            Text("RTK Efficiency").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: store.refresh) {
                // A plain swap rather than a rotationEffect: toggling between 0 and
                // 360 degrees made the icon unwind backwards when loading ended.
                ZStack {
                    if store.showsProgress {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            settingsMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var settingsMenu: some View {
        Menu {
            Picker("Refresh every", selection: $settings.refreshInterval) {
                ForEach(AppSettings.refreshChoices, id: \.self) { interval in
                    Text(intervalLabel(interval)).tag(interval)
                }
            }
            Toggle("Show percentage in menu bar", isOn: $settings.showPercentage)
            Toggle("Translucent panels", isOn: $settings.useGlass)
                .disabled(appearance.reduceTransparency)
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
            Divider()
            Button("Scope: \(settings.scopeLabel)…") { chooseScope() }
            if !settings.projectScope.isEmpty {
                Button("Use global stats") {
                    settings.projectScope = ""
                    store.refresh()
                }
            }
            Button("Set rtk path…") { chooseBinary() }
            Divider()
            Button("Check for Updates") { updater.check() }
                .disabled(!updater.canCheck)
            Text("Version \(updater.currentVersion.description)")
            if !settings.rtkPath.isEmpty {
                Button("Detect rtk automatically") {
                    settings.rtkPath = ""
                    store.refresh()
                }
            }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
        .help("Settings")
    }

    private func intervalLabel(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : "\(Int(seconds / 60)) min"
    }

    private func chooseScope() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use folder"
        panel.message = "Limit statistics to a project directory"
        if panel.runModal() == .OK, let url = panel.url {
            settings.projectScope = url.path
            store.refresh()
        }
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use binary"
        panel.message = "Select the rtk executable"
        if panel.runModal() == .OK, let url = panel.url {
            settings.rtkPath = url.path
            store.refresh()
        }
    }

// MARK: Update banner

    @ViewBuilder
    private var updateBanner: some View {
        switch updater.phase {
        case .upgrading:
            bannerRow(icon: "arrow.down.circle") {
                Text("Updating…").font(.system(size: 11, weight: .medium))
            } trailing: {
                ProgressView().controlSize(.small)
            }
        case .upgraded:
            bannerRow(icon: "checkmark.circle.fill") {
                Text("Update installed").font(.system(size: 11, weight: .medium))
            } trailing: {
                Button("Relaunch") { updater.relaunch() }
                    .controlSize(.small)
            }
        case .failed(let message):
            bannerRow(icon: "exclamationmark.triangle.fill") {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update failed").font(.system(size: 11, weight: .medium))
                    Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } trailing: {
                Button("Details") { updater.openReleasePage() }
                    .controlSize(.small)
            }
        case .idle, .checking:
            if let release = updater.newer {
                bannerRow(icon: "arrow.down.circle.fill") {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Version \(release.version.description) available")
                            .font(.system(size: 11, weight: .medium))
                        Text("You have \(updater.currentVersion.description)")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                } trailing: {
                    if updater.isHomebrewManaged {
                        Button("Update") { updater.upgrade() }.controlSize(.small)
                    } else {
                        Button("Download") { updater.openReleasePage() }.controlSize(.small)
                    }
                }
            }
        }
    }

    private func bannerRow<Label: View, Trailing: View>(
        icon: String,
        @ViewBuilder label: () -> Label,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.tint)
            label()
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background {
            if case .solid = panelStyle {
                Color(nsColor: .controlBackgroundColor)
            } else {
                Color.accentColor.opacity(0.10)
            }
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Sections

    private func gauge(_ s: GainSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.1f", s.avgSavingsPct))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("%").font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Fmt.compact(s.totalSaved)) tokens saved")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [.accentColor.opacity(0.7), .accentColor],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * min(max(s.avgSavingsPct, 0), 100) / 100)
                }
            }
            .frame(height: 8)
        }
    }

    private func statGrid(_ s: GainSummary) -> some View {
        let rows: [(String, String)] = [
            ("Commands", "\(s.totalCommands)"),
            ("Avg time", "\(s.avgTimeMs)ms"),
            ("Input", Fmt.compact(s.totalInput)),
            ("Output", Fmt.compact(s.totalOutput)),
            ("Saved", Fmt.compact(s.totalSaved)),
            ("Exec time", Fmt.duration(ms: s.totalTimeMs)),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                   GridItem(.flexible(), spacing: 12)],
                         alignment: .leading, spacing: 10) {
            ForEach(rows, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(value).font(.system(size: 13, weight: .medium)).monospacedDigit()
                }
            }
        }
    }

    private func dailyChart(_ daily: [GainDay]) -> some View {
        // A week fits the panel's width with room for readable date labels; two
        // weeks did not, and the overflow shifted the whole panel sideways.
        let days = Array(daily.suffix(7))
        let peak = max(days.map(\.savingsPct).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Daily savings", trailing: "last \(days.count)d · peak \(Fmt.pct(peak))")
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days) { day in
                    VStack(spacing: 4) {
                        Text(String(format: "%.0f", day.savingsPct))
                            .font(.system(size: 8)).monospacedDigit()
                            .foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.35 + 0.65 * day.savingsPct / 100))
                            .frame(height: max(3, 54 * day.savingsPct / peak))
                        Text(day.shortLabel)
                            .font(.system(size: 8)).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    // Equal columns: the chart's width is the panel's, never the
                    // sum of whatever its labels would like.
                    .frame(maxWidth: .infinity)
                    .help("\(day.date) — \(Fmt.pct(day.savingsPct)), "
                          + "\(Fmt.compact(day.savedTokens)) saved, \(day.commands) cmds")
                }
            }
            .frame(height: 80, alignment: .bottom)
        }
    }

    private func topCommands(_ top: [TopCommand]) -> some View {
        let items = Array(top.prefix(6))
        let maxSaved = max(items.map(\.savedTokens).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Top commands", trailing: "by tokens saved")
            VStack(spacing: 6) {
                ForEach(items) { cmd in
                    HStack(spacing: 8) {
                        Text(cmd.name)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                            .frame(width: 118, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.06))
                                Capsule().fill(Color.accentColor.opacity(0.55))
                                    .frame(width: geo.size.width * cmd.savedTokens / maxSaved)
                            }
                        }
                        .frame(height: 6)
                        Text(cmd.saved)
                            .font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                    .help("\(cmd.count) runs — \(Fmt.pct(cmd.pct)) avg savings")
                }
            }
        }
    }

    private func sectionTitle(_ text: String, trailing: String) -> some View {
        HStack {
            Text(text).font(.system(size: 11, weight: .semibold))
            Spacer()
            Text(trailing).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    private func errorBlock(_ error: RTKError) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("rtk unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
            Text(error.message).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(settings.scopeLabel)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .help(settings.projectScope.isEmpty
                      ? "Statistics across every project" : settings.projectScope)
            Spacer()
            if let d = store.lastUpdate {
                Text(d, style: .time)
                    .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
            }
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
