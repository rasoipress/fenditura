import SwiftUI
import UniformTypeIdentifiers
import FenditturaCore

@main
struct FenditturaApp: App {
    @StateObject private var engine = ScanEngine()

    var body: some Scene {
        Window("Fenditura", id: "main") {
            ContentView(engine: engine)
                .frame(minWidth: 900, minHeight: 580)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Apri video…") { openVideo(engine: engine) }
                    .keyboardShortcut("o")
                Button("Salva immagine…") { saveResult(engine: engine) }
                    .keyboardShortcut("s")
                    .disabled(!engine.hasResult)
                Divider()
                Button("Salva impostazioni…") { savePreset(engine: engine) }
                Button("Carica impostazioni…") { loadPreset(engine: engine) }
            }
            CommandMenu("Scansione") {
                Button(engine.isScanning ? "Ferma" : "Avvia") {
                    engine.isScanning ? engine.stop() : engine.start()
                }
                .keyboardShortcut(.return)
                Button("Adatta larghezza al moto") { engine.matchWidthToMotion() }
                    .keyboardShortcut("l")
                    .disabled(engine.measured == nil)
                Button("Scarta il risultato") { engine.discardResult() }
                    .keyboardShortcut(.delete, modifiers: .command)
                Divider()
                Picker("Modalità", selection: Binding(
                    get: { engine.settings.mode },
                    set: { engine.settings.mode = $0 })) {
                    ForEach(ScanMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
        }
    }
}

// MARK: - Dialoghi

@MainActor
func openVideo(engine: ScanEngine) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
    panel.allowsMultipleSelection = false
    panel.prompt = "Apri"
    if panel.runModal() == .OK, let url = panel.url { engine.open(url: url) }
}

@MainActor
func saveResult(engine: ScanEngine) {
    guard engine.hasResult else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = engine.defaultFileName
    if panel.runModal() == .OK, let url = panel.url { engine.export(to: url) }
}

@MainActor
func savePreset(engine: ScanEngine) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "fenditura.json"
    if panel.runModal() == .OK, let url = panel.url { engine.savePreset(to: url) }
}

@MainActor
func loadPreset(engine: ScanEngine) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { engine.loadPreset(from: url) }
}
