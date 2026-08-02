import SwiftUI
import UniformTypeIdentifiers
import FenditturaCore

/// L'interfaccia.
///
/// Nella finestra sta soltanto ciò che serve a decidere mentre si guarda: il
/// monitor con il taglio, il risultato che si forma, e una riga che dice se le
/// proporzioni sono giuste. Il resto vive nel pannello laterale.
struct ContentView: View {
    @ObservedObject var engine: ScanEngine
    @State private var showInspector = true

    var body: some View {
        VSplitView {
            monitor.frame(minHeight: 200)
            result.frame(minHeight: 160)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { gauge }
        .inspector(isPresented: $showInspector) {
            SettingsPanel(engine: engine)
                .inspectorColumnWidth(min: 270, ideal: 310, max: 400)
        }
        .toolbar { toolbarContent }
        .navigationTitle("Fenditura")
        .navigationSubtitle(engine.sourceName ?? "nessuna sorgente")
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in engine.open(url: url) }
            }
            return true
        }
        .overlay { if engine.isExporting { exportCurtain } }
    }

    // MARK: - Barra

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Picker("Modalità", selection: $engine.settings.mode) {
                ForEach(ScanMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        ToolbarItem { Button { openVideo(engine: engine) } label: { Label("Apri", systemImage: "film") } }
        ToolbarItem {
            Button { engine.isScanning ? engine.stop() : engine.start() } label: {
                Label(engine.isScanning ? "Ferma" : "Avvia",
                      systemImage: engine.isScanning ? "stop.fill" : "play.fill")
            }
            .disabled(engine.sourceName == nil)
        }
        ToolbarItem {
            Button { saveResult(engine: engine) } label: {
                Label("Salva", systemImage: "square.and.arrow.down")
            }
            .disabled(!engine.hasResult || engine.isExporting)
        }
        ToolbarItem {
            Button { showInspector.toggle() } label: {
                Label("Impostazioni", systemImage: "sidebar.trailing")
            }
        }
    }

    // MARK: - Monitor

    /// Immagine e taglio devono condividere lo stesso rettangolo.
    ///
    /// Applicare `aspectRatio(.fit)` all'immagine e sovrapporle il taglio non
    /// funziona: la vista immagine occupa tutto il contenitore e disegna il
    /// fotogramma centrato dentro, quindi la sovrapposizione copre anche le
    /// bande vuote ai lati e la riga rossa finisce dove il video non c'è —
    /// spesso fuori dall'immagine, e sembra sparita. Il vincolo di proporzione
    /// va messo sullo stack che le contiene entrambe.
    private var monitor: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let image = engine.sourcePreview, engine.sourceSize.height > 0 {
                ZStack {
                    Image(nsImage: image).resizable()
                    SlitOverlay(engine: engine)
                }
                .aspectRatio(engine.sourceSize.width / engine.sourceSize.height,
                             contentMode: .fit)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Trascina qui un video, o premi Apri.")
                        .foregroundStyle(.secondary)
                    Text("Il file resta sul tuo computer.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Risultato

    private var result: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor).opacity(0.3)
            if let image = engine.preview {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
            } else {
                Text(engine.settings.mode == .timeDisplacement
                     ? "l’immagine si riempirà colonna per colonna"
                     : "la striscia comparirà qui")
                    .font(.callout).foregroundStyle(.tertiary)
            }
        }
        .overlay(alignment: .topLeading) {
            if engine.hasResult {
                Text(engine.outputSizeDescription)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
    }

    // MARK: - Quadrante

    private var gauge: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text("moto sotto la fenditura")
                    .font(.caption2).foregroundStyle(.tertiary)
                Text(engine.measured.map { String(format: "%.2f px/fetta", $0) } ?? "—")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(verdictColor)
            }
            .frame(minWidth: 150, alignment: .leading)

            Text(verdictText)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if needsMatch {
                Button("Adatta") { engine.matchWidthToMotion() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottomLeading) {
            if let message = engine.statusMessage {
                Text(message).font(.caption2).foregroundStyle(.tertiary)
                    .padding(.leading, 16).padding(.bottom, 1)
            }
        }
    }

    private var needsMatch: Bool {
        switch engine.verdict {
        case .stretched, .squashed: return engine.settings.mode != .timeDisplacement
        default: return false
        }
    }

    private var verdictColor: Color {
        switch engine.verdict {
        case .unknown: return .secondary
        case .still, .tooFast: return .red
        case .stretched, .squashed: return .orange
        case .correct: return .green
        }
    }

    private var verdictText: String {
        if engine.settings.mode == .timeDisplacement {
            return "In time displacement le proporzioni non dipendono dalla larghezza della fenditura: l’immagine ha le dimensioni del fotogramma. Il valore accanto dice solo quanto si muove la scena."
        }
        switch engine.verdict {
        case .unknown:
            return "Carica un video e avvia. Qui compare lo spostamento reale dell’immagine fra una fetta e la successiva."
        case .still:
            return "L’immagine è ferma sotto la fenditura. Se la camera insegue il soggetto è previsto: sposta il taglio dove scorre lo sfondo, o usa una traiettoria."
        case .tooFast(let d):
            return String(format: "Lo spostamento è di %.0f px per fetta, oltre la fenditura più larga possibile. Alza il passo di campionamento, o riprendi a più fotogrammi al secondo.", d)
        case .stretched(let times, let suggested):
            return String(format: "Fenditura più larga del moto: il soggetto esce stirato di circa %.1f volte. La larghezza giusta è %d px.", times, suggested)
        case .squashed(let times, let suggested):
            return String(format: "Fenditura più stretta del moto: il soggetto esce schiacciato di circa %.1f volte. La larghezza giusta è %d px.", times, suggested)
        case .correct:
            return "Proporzioni corrette. Le forme sono quelle del soggetto reale."
        }
    }

    private var exportCurtain: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 14) {
                Text("Scrittura dell’immagine").font(.headline)
                ProgressView(value: engine.exportFraction).frame(width: 260)
                Text(engine.outputSizeDescription)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Annulla", role: .cancel) { engine.cancelExport() }
            }
            .padding(28)
        }
    }
}

// MARK: - Il taglio sul monitor

private struct SlitOverlay: View {
    @ObservedObject var engine: ScanEngine

    var body: some View {
        GeometryReader { geo in
            let vertical = engine.settings.axis == .vertical
            let span = vertical ? geo.size.width : geo.size.height
            let position = engine.settings.basePosition * span
            let cross = max(engine.crossSizeSource, 1)
            // Spessore in pixel dello schermo, non della sorgente: una
            // fenditura da 4 px su un video 4K vale meno di un pixel a video,
            // e senza un minimo non si vedrebbe niente.
            let thickness = max(3, engine.settings.kernel.width / Double(cross) * span)

            ZStack(alignment: .topLeading) {
                if engine.settings.kernel.feather > 0 {
                    Rectangle()
                        .fill(Color.red.opacity(0.16))
                        .frame(width: vertical ? thickness * 2.4 : geo.size.width,
                               height: vertical ? geo.size.height : thickness * 2.4)
                        .blur(radius: thickness * engine.settings.kernel.feather)
                        .offset(x: vertical ? position - thickness * 1.2 : 0,
                                y: vertical ? 0 : position - thickness * 1.2)
                }
                Rectangle()
                    .fill(Color.red.opacity(0.26))
                    .frame(width: vertical ? thickness : geo.size.width,
                           height: vertical ? geo.size.height : thickness)
                    .offset(x: vertical ? position - thickness / 2 : 0,
                            y: vertical ? 0 : position - thickness / 2)
                Rectangle()
                    .fill(Color.red)
                    .frame(width: vertical ? 1.5 : geo.size.width * 1.8,
                           height: vertical ? geo.size.height * 1.8 : 1.5)
                    .rotationEffect(.radians(vertical ? engine.settings.kernel.angle
                                                      : -engine.settings.kernel.angle))
                    .offset(x: vertical ? position : -geo.size.width * 0.4,
                            y: vertical ? -geo.size.height * 0.4 : position)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let raw = vertical ? value.location.x / geo.size.width
                                       : value.location.y / geo.size.height
                    engine.settings.basePosition = min(max(raw, 0), 1)
                }
            )
        }
    }
}

// MARK: - Pannello

/// Il pannello usa una `ScrollView` esplicita invece di una `Form`.
///
/// Con `Form(.grouped)` dentro un ispettore lo scorrimento si inceppa: le
/// sezioni compaiono e spariscono al cambio di modalità, l'altezza del
/// contenuto cambia sotto la vista, e la posizione di scorrimento resta
/// agganciata a righe che non esistono più — il pannello sembra bloccato. Con
/// una `ScrollView` e un `VStack` il contenuto è uno solo e non c'è niente a
/// cui restare appesi.
private struct SettingsPanel: View {
    @ObservedObject var engine: ScanEngine

    private var s: Binding<ScanSettings> { $engine.settings }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                slitSection
                if engine.settings.mode != .timeDisplacement { trajectorySection }
                smoothnessSection
                outputSection
                if engine.settings.mode == .multiStrip { multiSection }
                if engine.settings.mode == .timeDisplacement { displacementSection }
                counters
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: sezioni

    private var slitSection: some View {
        group("Fenditura") {
            if engine.settings.mode != .timeDisplacement {
                knob("Posizione", String(format: "%.1f %%", engine.settings.basePosition * 100)) {
                    Slider(value: Binding(get: { engine.settings.basePosition },
                                          set: { engine.settings.basePosition = $0 }), in: 0...1)
                }
            }
            knob("Larghezza", String(format: "%.2f px", engine.settings.kernel.width)) {
                Slider(value: s.kernel.width, in: 0.25...96)
            }
            knob("Sfumatura", String(format: "%.0f %%", engine.settings.kernel.feather * 100)) {
                Slider(value: s.kernel.feather, in: 0...1)
            }
            knob("Inclinazione", String(format: "%.0f°", engine.settings.kernel.angle * 180 / .pi)) {
                Slider(value: s.kernel.angle, in: -1.2...1.2)
            }
            note("La sfumatura media i pixel della finestra con pesi a campana invece di copiarli a peso pieno: il taglio netto diventa uno strisciato da lunga esposizione.")
        }
    }

    private var trajectorySection: some View {
        group("Traiettoria") {
            Picker("", selection: trajectoryKind) {
                Text("Ferma").tag(0)
                Text("Deriva").tag(1)
                Text("Chiavi").tag(2)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if case .linear = engine.settings.trajectory {
                knob("Deriva", String(format: "%.2f px/fetta", engine.settings.drift)) {
                    Slider(value: Binding(get: { engine.settings.drift },
                                          set: { engine.settings.drift = $0 }), in: -8...8)
                }
            }
            if case .keyframed(let keys, _) = engine.settings.trajectory {
                HStack {
                    Text("\(keys.count) chiavi").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Aggiungi qui") { addKeyframe() }.controlSize(.small)
                    Button("Svuota") {
                        engine.settings.trajectory = .keyframed(
                            keys: [.init(slice: 0, position: engine.settings.basePosition)],
                            easing: .smooth)
                    }.controlSize(.small)
                }
                note("Sposta la fenditura sul monitor e premi «Aggiungi qui»: la chiave finisce alla fetta corrente. Fra due chiavi l’app interpola con raccordo morbido.")
            }
        }
    }

    /// La sezione che risponde alla domanda «come si fa a renderla liscia».
    private var smoothnessSection: some View {
        group("Morbidezza") {
            knob("Fotogrammi mediati", "\(engine.settings.temporalWindow)") {
                Slider(value: Binding(get: { Double(engine.settings.temporalWindow) },
                                      set: { engine.settings.temporalWindow = Int($0.rounded()) }),
                       in: 1...24, step: 1)
            }
            knob("Morbidezza del tempo",
                 String(format: "%.0f %%", engine.settings.temporalFeather * 100)) {
                Slider(value: s.temporalFeather, in: 0...1)
            }
            note("Uno: ogni colonna viene da un istante solo e gli stacchi si vedono. Due: resta un doppio contorno. Da otto in su è una lunga esposizione sull’asse del tempo, ed è ciò che rende continue le transizioni.")
            if engine.settings.temporalWindow > 12 {
                Label("Finestre larghe rallentano molto la scansione.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var outputSection: some View {
        group("Uscita") {
            Picker("Orientamento", selection: s.axis) {
                Text("Fenditura verticale").tag(StripBuffer.Axis.vertical)
                Text("Fenditura orizzontale").tag(StripBuffer.Axis.horizontal)
            }
            knob("Scala", "\(Int(engine.settings.scale * 100)) %") {
                Slider(value: s.scale, in: 0.1...1.0)
            }
            Stepper("Una fetta ogni \(engine.settings.step) fotogrammi", value: s.step, in: 1...16)
            Toggle(engine.settings.mode == .timeDisplacement ? "Tempo invertito" : "Accumula all’indietro",
                   isOn: s.reversed)
            Toggle("Stabilizza esposizione", isOn: s.stabiliseExposure)
            if engine.settings.mode != .timeDisplacement {
                Toggle("Raddoppia specchiando", isOn: s.mirrored)
                knob("Lunghezza massima", "\(engine.settings.maxLength) px") {
                    Slider(value: Binding(get: { Double(engine.settings.maxLength) },
                                          set: { engine.settings.maxLength = Int($0) }),
                           in: 1000...500_000)
                }
            }
        }
    }

    private var multiSection: some View {
        group("Strisce multiple") {
            Stepper("\(engine.settings.stripCount) strisce", value: s.stripCount, in: 2...8)
            knob("Distanza", String(format: "%.0f %%", engine.settings.stripSpread * 100)) {
                Slider(value: s.stripSpread, in: 0.05...1.0)
            }
        }
    }

    private var displacementSection: some View {
        group("Time displacement") {
            knob("Porzione di filmato",
                 String(format: "%.0f %%", engine.settings.timeSpread * 100)) {
                Slider(value: s.timeSpread, in: 0.05...1.0)
            }
            note("A cento per cento l’immagine copre tutto il video. Riducendo, si spalma solo l’inizio.")
        }
    }

    private var counters: some View {
        HStack {
            Text("Fette catturate").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(engine.capturedSlices)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    // MARK: mattoni

    private func group<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .kerning(0.6)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func knob<Content: View>(_ title: String, _ value: String,
                                     @ViewBuilder control: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            control()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var trajectoryKind: Binding<Int> {
        Binding(
            get: {
                switch engine.settings.trajectory {
                case .fixed: return 0
                case .linear: return 1
                case .keyframed: return 2
                }
            },
            set: { kind in
                let p = engine.settings.basePosition
                switch kind {
                case 0: engine.settings.trajectory = .fixed(position: p)
                case 1: engine.settings.trajectory = .linear(position: p, drift: 0)
                default: engine.settings.trajectory = .keyframed(
                    keys: [.init(slice: 0, position: p)], easing: .smooth)
                }
            }
        )
    }

    private func addKeyframe() {
        guard case .keyframed(var keys, let easing) = engine.settings.trajectory else { return }
        keys.append(.init(slice: engine.capturedSlices, position: engine.settings.basePosition))
        engine.settings.trajectory = .keyframed(keys: keys, easing: easing)
    }
}
