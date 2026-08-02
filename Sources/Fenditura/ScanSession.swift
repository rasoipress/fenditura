import Foundation
import AVFoundation
import CoreGraphics
import AppKit
import FenditturaCore

/// Una passata di scansione.
///
/// Vive interamente sulla coda di lettura e non tocca mai il thread
/// principale: spedisce aggiornamenti, non li aspetta. Un video a 240
/// fotogrammi al secondo produrrebbe altrimenti quattro sincronizzazioni al
/// millisecondo, e l'interfaccia si fermerebbe.
///
/// Le quattro modalità non sono quattro algoritmi. Per ogni colonna
/// dell'uscita servono le stesse due risposte — da quale istante, da quale
/// posizione — e cambia solo chi le fornisce.
final class ScanSession: @unchecked Sendable {

    // Asset, traccia e durata arrivano già caricati dal motore, che li legge
    // con le API asincrone. Rileggerli qui costringerebbe a usare le versioni
    // sincrone di AVFoundation, deprecate da macOS 13 perché bloccano il
    // thread chiamante mentre il file viene interrogato.
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let duration: Double
    private let live: LiveSettings
    private let flag: CancelFlag
    private let meter = MotionMeter()

    /// Strisce accumulate. Una sola, salvo la modalità a strisce multiple.
    private(set) var strips: [StripBuffer] = []
    /// Tela del time displacement, quando è quella la modalità.
    private(set) var canvas: TimeDisplacementCanvas?

    private var luminanceReference: Double?
    private var luminanceSamples = 0
    private var captured = 0

    private static let exposureFrames = 8

    init(asset: AVAsset, track: AVAssetTrack, duration: Double,
         live: LiveSettings, flag: CancelFlag) {
        self.asset = asset
        self.track = track
        self.duration = duration
        self.live = live
        self.flag = flag
    }

    // MARK: - Passata

    func run(onUpdate: @escaping (ScanUpdate) -> Void,
             completion: @escaping (String?) -> Void) {

        guard let reader = try? AVAssetReader(asset: asset) else {
            completion("non riesco ad avviare la lettura del video")
            return
        }

        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            completion("questo formato video non è leggibile")
            return
        }
        reader.add(output)
        reader.startReading()

        var frameIndex = 0
        var reason: String? = "fine del video"

        // Anello dei fotogrammi recenti. Mediare su una finestra è ciò che
        // rende continue le transizioni: con un fotogramma solo si vedono gli
        // stacchi, con due un doppio contorno, con dodici una lunga
        // esposizione. La finestra si legge a ogni giro perché l'utente può
        // cambiarla mentre la scansione procede.
        var ring: [(buffer: CVPixelBuffer, time: Double)] = []

        while reader.status == .reading {
            if flag.isRaised { reason = nil; break }
            guard let sample = output.copyNextSampleBuffer() else { break }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds

            let settings = live.current
            let window = max(1, settings.temporalWindow)

            // `CVPixelBuffer` arriva da un pool riutilizzato: senza copia i
            // fotogrammi dell'anello verrebbero sovrascritti prima dell'uso.
            ring.append((retain(buffer), time))
            if ring.count > window { ring.removeFirst() }
            frameIndex += 1

            guard ring.count == window, frameIndex % max(1, settings.step) == 0 else { continue }

            consume(window: ring, settings: settings)
            if let stop = checkLimit(settings) {
                reason = stop
                push(onUpdate, settings: settings, preview: true)
                break
            }
            if captured % 4 == 0 {
                push(onUpdate, settings: settings, preview: captured % 16 == 0)
            }
        }

        // La coda del video: la finestra non si riempie più, ma i fotogrammi
        // rimasti sono comunque immagine da mettere nella striscia.
        if !ring.isEmpty, reason != nil {
            consume(window: ring, settings: live.current)
        }

        if reader.status == .failed {
            reason = "lettura interrotta: \(reader.error?.localizedDescription ?? "errore sconosciuto")"
        }
        reader.cancelReading()

        push(onUpdate, settings: live.current, preview: true)
        completion(reason)
    }

    private func retain(_ buffer: CVPixelBuffer) -> CVPixelBuffer {
        // Il buffer arriva da un pool riutilizzato: senza una copia il
        // fotogramma "precedente" verrebbe sovrascritto prima di essere usato,
        // e l'interpolazione temporale fonderebbe un fotogramma con sé stesso.
        var copy: CVPixelBuffer?
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &copy)
        guard let dst = copy else { return buffer }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        if let s = CVPixelBufferGetBaseAddress(buffer), let d = CVPixelBufferGetBaseAddress(dst) {
            let srcStride = CVPixelBufferGetBytesPerRow(buffer)
            let dstStride = CVPixelBufferGetBytesPerRow(dst)
            let rowBytes = min(srcStride, dstStride)
            for y in 0..<h {
                memcpy(d.advanced(by: y * dstStride), s.advanced(by: y * srcStride), rowBytes)
            }
        }
        CVPixelBufferUnlockBaseAddress(dst, [])
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        return dst
    }

    private func checkLimit(_ settings: ScanSettings) -> String? {
        if settings.mode == .timeDisplacement {
            return canvas?.isComplete == true ? "immagine completa" : nil
        }
        if let first = strips.first, first.length >= settings.maxLength {
            return "lunghezza massima raggiunta"
        }
        return nil
    }

    // MARK: - Un fotogramma

    /// Consuma una finestra di fotogrammi, producendo una fetta.
    ///
    /// Tutti i fotogrammi della finestra vengono bloccati insieme e passati al
    /// campionatore con i loro pesi: la media avviene dentro il campionamento,
    /// non su immagini già prodotte, quindi non c'è nessun passaggio
    /// intermedio a 8 bit che perda precisione.
    private func consume(window: [(buffer: CVPixelBuffer, time: Double)],
                         settings: ScanSettings) {
        guard let first = window.first else { return }

        for entry in window { CVPixelBufferLockBaseAddress(entry.buffer, .readOnly) }
        defer { for entry in window { CVPixelBufferUnlockBaseAddress(entry.buffer, .readOnly) } }

        var sources: [PixelSource] = []
        sources.reserveCapacity(window.count)
        for entry in window {
            guard let base = CVPixelBufferGetBaseAddress(entry.buffer) else { continue }
            sources.append(PixelSource(base: base.assumingMemoryBound(to: UInt8.self),
                                       width: CVPixelBufferGetWidth(entry.buffer),
                                       height: CVPixelBufferGetHeight(entry.buffer),
                                       stride: CVPixelBufferGetBytesPerRow(entry.buffer)))
        }
        guard let a = sources.first else { return }

        let weights = SlitSampler.temporalWeights(count: sources.count,
                                                  feather: settings.temporalFeather)
        let width = a.width
        let height = a.height
        let cross = settings.axis == .vertical ? width : height
        let profile = luminanceProfile(a, axis: settings.axis)

        var gain = 1.0
        if settings.stabiliseExposure {
            let mean = meanLuminance(profile: profile,
                                     centre: settings.trajectory.position(atSlice: captured, crossSize: cross),
                                     cross: cross)
            if luminanceSamples < Self.exposureFrames {
                let n = Double(luminanceSamples)
                luminanceReference = ((luminanceReference ?? 0) * n + mean) / (n + 1)
                luminanceSamples += 1
            } else if let ref = luminanceReference, mean > 4 {
                gain = min(max(ref / mean, 0.35), 2.8)
            }
        }

        switch settings.mode {
        case .strip, .rollout:
            appendStrips(sources: sources, weights: weights, settings: settings,
                         width: width, height: height, gain: gain,
                         centres: [centre(settings, cross: cross)])
        case .multiStrip:
            appendStrips(sources: sources, weights: weights, settings: settings,
                         width: width, height: height, gain: gain,
                         centres: multiCentres(settings, cross: cross))
        case .timeDisplacement:
            let last = window[window.count - 1]
            fillCanvas(sources: sources, weights: weights, settings: settings,
                       width: width, height: height, gain: gain,
                       progress: first.time / max(duration, 0.001),
                       nextProgress: (last.time + (last.time - first.time) / Double(max(window.count - 1, 1)))
                                     / max(duration, 0.001))
        }

        captured += 1
        if captured % 2 == 0 {
            meter.submit(profile: profile, frameIndex: captured, crossSize: cross)
        }
    }

    private func centre(_ settings: ScanSettings, cross: Int) -> Double {
        settings.trajectory.position(atSlice: captured, crossSize: cross)
    }

    private func multiCentres(_ settings: ScanSettings, cross: Int) -> [Double] {
        let n = settings.stripCount
        let span = Double(cross) * settings.stripSpread
        let start = Double(cross) / 2 - span / 2
        guard n > 1 else { return [Double(cross) / 2] }
        return (0..<n).map { start + span * Double($0) / Double(n - 1) }
    }

    // MARK: - Strisciata

    private func appendStrips(sources: [PixelSource], weights: [Double], settings: ScanSettings,
                              width: Int, height: Int, gain: Double,
                              centres: [Double]) {
        let outCross = max(1, Int((Double(settings.axis == .vertical ? height : width) * settings.scale).rounded()))
        if strips.count != centres.count {
            strips = centres.map { _ in StripBuffer(axis: settings.axis, cross: outCross) }
        }
        let step = max(1, Int((settings.kernel.width * settings.scale).rounded()))

        for (i, c) in centres.enumerated() where i < strips.count {
            var slice = [UInt8](repeating: 255, count: step * outCross * 4)
            SlitSampler.slice(frames: sources, weights: weights,
                              axis: settings.axis, centre: c, kernel: settings.kernel,
                              outCross: outCross, outStep: step, gain: gain, into: &slice)
            strips[i].append(slice: slice, step: step)
        }
    }

    // MARK: - Time displacement

    private func fillCanvas(sources: [PixelSource], weights: [Double], settings: ScanSettings,
                            width: Int, height: Int, gain: Double,
                            progress: Double, nextProgress: Double) {
        let w = max(1, Int(Double(width) * settings.scale))
        let h = max(1, Int(Double(height) * settings.scale))
        if canvas == nil || canvas!.width != w || canvas!.height != h {
            canvas = TimeDisplacementCanvas(width: w, height: h, axis: settings.axis)
        }
        guard let canvas,
              let range = canvas.range(progress: progress, nextProgress: nextProgress,
                                       spread: settings.timeSpread, reversed: settings.reversed)
        else { return }

        let crossOut = settings.axis == .vertical ? h : w
        let span = Double(canvas.timeSpan)

        for index in range {
            // In questa modalità la colonna resta dov'è: la posizione nel
            // fotogramma è la posizione nell'immagine. È tutta la differenza
            // rispetto alla strisciata.
            let sourceCentre = (Double(index) + 0.5) / span *
                Double(settings.axis == .vertical ? width : height)
            var line = [UInt8](repeating: 255, count: crossOut * 4)
            SlitSampler.slice(frames: sources, weights: weights,
                              axis: settings.axis, centre: sourceCentre,
                              kernel: settings.kernel,
                              outCross: crossOut, outStep: 1, gain: gain, into: &line)
            canvas.write(line: line, at: index)
        }
    }

    // MARK: - Analisi

    private func luminanceProfile(_ s: PixelSource, axis: StripBuffer.Axis) -> [Float] {
        let n = MotionMeter.profileSize
        var out = [Float](repeating: 0, count: n)
        let samples = 48
        for i in 0..<n {
            var sum = 0.0
            if axis == .vertical {
                let x = min(s.width - 1, i * s.width / n)
                for k in 0..<samples {
                    let y = min(s.height - 1, k * s.height / samples)
                    let p = s.base + y * s.stride + x * 4
                    sum += 0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])
                }
            } else {
                let y = min(s.height - 1, i * s.height / n)
                let row = s.base + y * s.stride
                for k in 0..<samples {
                    let x = min(s.width - 1, k * s.width / samples)
                    let p = row + x * 4
                    sum += 0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])
                }
            }
            out[i] = Float(sum / Double(samples))
        }
        return out
    }

    private func meanLuminance(profile: [Float], centre: Double, cross: Int) -> Double {
        guard !profile.isEmpty, cross > 0 else { return 0 }
        let i = min(max(Int((centre / Double(cross)) * Double(profile.count)), 0), profile.count - 1)
        return Double(profile[i])
    }

    // MARK: - Aggiornamenti

    private func push(_ onUpdate: (ScanUpdate) -> Void, settings: ScanSettings, preview: Bool) {
        onUpdate(ScanUpdate(
            slices: captured,
            length: settings.mode == .timeDisplacement ? (canvas?.filledCount ?? 0) : (strips.first?.length ?? 0),
            measured: meter.measured,
            verdict: meter.verdict(sliceWidth: Int(settings.kernel.width.rounded()),
                                   maxWidth: Int(ScanSettings.Limits.slitWidth.upperBound)),
            preview: preview ? makePreview(settings) : nil
        ))
    }

    private func makePreview(_ settings: ScanSettings) -> NSImage? {
        if settings.mode == .timeDisplacement, let canvas, canvas.filledCount > 0 {
            return PreviewImage.make(canvas.pixels, width: canvas.width, height: canvas.height)
        }
        guard let strip = strips.first, strip.length > 0,
              let tile = strip.tiles.last, tile.fill > 0 else { return nil }

        let cross = strip.cross
        let visible = min(tile.fill, 1400)
        let offset = tile.fill - visible
        var pixels: [UInt8]
        let w: Int, h: Int
        switch strip.axis {
        case .vertical:
            w = visible; h = cross
            pixels = [UInt8](repeating: 0, count: w * h * 4)
            let tileRow = StripBuffer.tileLength * 4
            for y in 0..<h {
                let s = y * tileRow + offset * 4
                pixels.replaceSubrange((y * w * 4)..<((y + 1) * w * 4), with: tile.pixels[s..<(s + w * 4)])
            }
        case .horizontal:
            w = cross; h = visible
            let s = offset * cross * 4
            pixels = Array(tile.pixels[s..<(s + visible * cross * 4)])
        }
        return PreviewImage.make(pixels, width: w, height: h)
    }
}

/// Da pixel RGBA a immagine mostrabile.
enum PreviewImage {
    static func make(_ pixels: [UInt8], width: Int, height: Int) -> NSImage? {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return nil }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: width, height: height,
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }
}
