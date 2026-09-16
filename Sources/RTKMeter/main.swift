import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if CommandLine.arguments.contains("--print-appearance") {
    print(AppearanceMonitor().summary)
    exit(0)
}

if let preview = PreviewRenderer.outputPath(from: CommandLine.arguments) {
    exit(PreviewRenderer.render(to: preview.png, fixture: preview.fixture))
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
