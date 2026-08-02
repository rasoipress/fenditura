import Foundation
import AVFoundation
import CoreGraphics
import AppKit
import FenditturaCore

/// Impostazioni condivise fra l'interfaccia e il thread di scansione.
///
/// Servono a poter spostare la fenditura mentre la scansione procede, che è il
/// motivo per cui questo programma esiste: si corregge guardando. Un lucchetto
/// attorno a una struct piccola costa quanto niente e non obbliga il thread di
/// lettura a fermarsi su quello principale a ogni fotogramma.
final class LiveSettings: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ScanSettings

    init(_ initial: ScanSettings) { value = initial.clamped() }

    var current: ScanSettings {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func update(_ new: ScanSettings) {
        lock.lock(); defer { lock.unlock() }
        value = new.clamped()
    }
}

/// Bandiera di annullamento leggibile da qualunque thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    func raise() { lock.lock(); raised = true; lock.unlock() }
    func lower() { lock.lock(); raised = false; lock.unlock() }
}

/// Aggiornamento che il thread di scansione manda all'interfaccia.
///
/// `NSImage` non è marcata Sendable, ma questa istanza viene costruita sulla
/// coda di scansione e da lì in poi non la tocca più nessuno.
struct ScanUpdate: @unchecked Sendable {
    var slices: Int
    var length: Int
    var measured: Double?
    var verdict: MotionMeter.Verdict
    var preview: NSImage?
}

@MainActor
final class ScanEngine: ObservableObject {

    // Sorgente
    @Published private(set) var sourceName: String?
    @Published private(set) var sourceSize: CGSize = .zero
    @Published private(set) var duration: Double = 0
    @Published private(set) var sourcePreview: NSImage?

    // Stato
    @Published private(set) var isScanning = false
    @Published private(set) var isExporting = false
    @Published private(set) var capturedSlices = 0
    @Published private(set) var outputLength = 0
    @Published private(set) var statusMessage: String?
    @Published private(set) var exportFraction: Double = 0

    // Misura
    @Published private(set) var measured: Double?
    @Published private(set) var verdict: MotionMeter.Verdict = .unknown
    @Published private(set) var preview: NSImage?

    @Published var settings = ScanSettings() {
        didSet {
            live.update(settings)
            if settings.mode != oldValue.mode
                || settings.axis != oldValue.axis
                || settings.scale != oldValue.scale
                || settings.stripCount != oldValue.stripCount {
                discardResult()
            }
        }
    }

    private let live = LiveSettings(ScanSettings())
    private let flag = CancelFlag()
    private let queue = DispatchQueue(label: "fenditura.scan", qos: .userInitiated)
    private var assetURL: URL?
    private var session: ScanSession?
    private var suggestedWidth: Int?

    var hasResult: Bool { outputLength > 0 }

    // MARK: - Sorgente

    func open(url: URL) {
        stop()
        discardResult()
        assetURL = url
        sourceName = url.lastPathComponent
        statusMessage = nil

        Task { @MainActor in
            let asset = AVURLAsset(url: url)
            do {
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    statusMessage = "questo file non contiene una traccia video"
                    sourceName = nil
                    return
                }
                let natural = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let applied = natural.applying(transform)
                sourceSize = CGSize(width: abs(applied.width), height: abs(applied.height))
                duration = try await asset.load(.duration).seconds
                sourcePreview = await Self.firstFrame(asset: asset)
            } catch {
                statusMessage = "non riesco a leggere il video: \(error.localizedDescription)"
                sourceName = nil
            }
        }
    }

    private static func firstFrame(asset: AVAsset) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1200, height: 1200)
        guard let (cg, _) = try? await generator.image(at: .zero) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    var crossSizeSource: Int {
        settings.axis == .vertical ? Int(sourceSize.width) : Int(sourceSize.height)
    }

    // MARK: - Scansione

    func discardResult() {
        guard !isScanning else { return }
        session = nil
        outputLength = 0
        capturedSlices = 0
        measured = nil
        suggestedWidth = nil
        verdict = .unknown
        preview = nil
    }

    func start() {
        guard !isScanning, !isExporting, let url = assetURL, sourceSize.width > 0 else { return }
        live.update(settings)
        flag.lower()
        isScanning = true
        statusMessage = nil
        discardResult()

        // Traccia e durata si caricano qui, con le API asincrone. Farlo dentro
        // la sessione obbligherebbe a usare le versioni sincrone, deprecate da
        // macOS 13 perché bloccano il thread mentre interrogano il file.
        Task { @MainActor in
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let seconds = try? await asset.load(.duration).seconds else {
                self.isScanning = false
                self.statusMessage = "non riesco a leggere la traccia video"
                return
            }

            let session = ScanSession(asset: asset, track: track, duration: seconds,
                                      live: self.live, flag: self.flag)
            self.session = session
            self.queue.async { [weak self] in
                session.run { update in
                    Task { @MainActor in self?.apply(update) }
                } completion: { reason in
                    Task { @MainActor in
                        self?.isScanning = false
                        self?.statusMessage = reason
                    }
                }
            }
        }
    }

    func stop() {
        flag.raise()
        isScanning = false
    }

    private func apply(_ update: ScanUpdate) {
        capturedSlices = update.slices
        outputLength = update.length
        measured = update.measured
        verdict = update.verdict
        if let image = update.preview { preview = image }
        switch update.verdict {
        case .stretched(_, let w), .squashed(_, let w): suggestedWidth = w
        case .correct: if let m = update.measured { suggestedWidth = Int(m.rounded()) }
        default: break
        }
    }

    func matchWidthToMotion() {
        guard let w = suggestedWidth ?? measured.map({ Int($0.rounded()) }) else { return }
        settings.kernel.width = min(max(Double(w), ScanSettings.Limits.slitWidth.lowerBound),
                                    ScanSettings.Limits.slitWidth.upperBound)
    }

    // MARK: - Salvataggio

    func export(to url: URL) {
        guard let session, hasResult, !isExporting else { return }
        stop()
        isExporting = true
        exportFraction = 0
        flag.lower()

        let settings = self.settings
        let cancel = flag

        queue.async { [weak self] in
            var failure: String?
            do {
                if settings.mode == .timeDisplacement {
                    guard let canvas = session.canvas else { throw StripExporter.Failure.empty }
                    try canvas.write(to: url)
                } else if settings.mode == .multiStrip && session.strips.count > 1 {
                    try StripExporter.writeStacked(
                        strips: session.strips, to: url,
                        reversedOrder: settings.reversed, mirrored: settings.mirrored, gap: 12,
                        onProgress: { p in Task { @MainActor in self?.exportFraction = p.fraction } },
                        shouldContinue: { !cancel.isRaised })
                } else {
                    guard let strip = session.strips.first else { throw StripExporter.Failure.empty }
                    try StripExporter.write(
                        strip: strip, to: url,
                        reversedOrder: settings.reversed, mirrored: settings.mirrored,
                        onProgress: { p in Task { @MainActor in self?.exportFraction = p.fraction } },
                        shouldContinue: { !cancel.isRaised })
                }
            } catch {
                failure = "\(error)"
            }
            let message = failure
            Task { @MainActor in
                self?.isExporting = false
                self?.exportFraction = 0
                self?.statusMessage = message ?? "immagine salvata"
                if message == nil { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    func cancelExport() { flag.raise() }

    // MARK: - Impostazioni su file

    func savePreset(to url: URL) {
        do {
            try settings.jsonData().write(to: url)
            statusMessage = "impostazioni salvate"
        } catch {
            statusMessage = "non riesco a salvare le impostazioni"
        }
    }

    func loadPreset(from url: URL) {
        do {
            settings = try ScanSettings.from(jsonData: Data(contentsOf: url))
            statusMessage = "impostazioni caricate"
        } catch {
            statusMessage = "file di impostazioni non leggibile"
        }
    }

    // MARK: - Descrizioni

    var outputSizeDescription: String {
        guard let session else { return "—" }
        if settings.mode == .timeDisplacement, let c = session.canvas {
            return "\(c.width) × \(c.height) px"
        }
        guard let strip = session.strips.first, strip.length > 0 else { return "—" }
        let s = strip.outputSize(mirrored: settings.mirrored)
        if settings.mode == .multiStrip {
            let n = session.strips.count
            return "\(s.width) × \(s.height * n + 12 * (n - 1)) px · \(n) strisce"
        }
        return "\(s.width) × \(s.height) px"
    }

    var defaultFileName: String {
        let stem = (sourceName as NSString?)?.deletingPathExtension ?? "fenditura"
        let suffix: String
        switch settings.mode {
        case .strip: suffix = "strisciata"
        case .timeDisplacement: suffix = "displacement"
        case .rollout: suffix = "srotolamento"
        case .multiStrip: suffix = "strisce"
        }
        return "\(stem)-\(suffix).png"
    }
}
