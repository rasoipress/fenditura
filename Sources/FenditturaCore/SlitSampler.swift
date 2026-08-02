import Foundation

/// Un fotogramma decodificato, in BGRA.
///
/// Non possiede la memoria: punta a quella del decodificatore o, nelle prove,
/// a un array. Serve per campionare senza copiare un fotogramma intero.
public struct PixelSource {
    public let base: UnsafePointer<UInt8>
    public let width: Int
    public let height: Int
    public let stride: Int

    public init(base: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) {
        self.base = base
        self.width = width
        self.height = height
        self.stride = stride
    }
}

/// Forma della fenditura.
public struct SlitKernel: Equatable, Sendable {
    /// Larghezza in pixel della sorgente. Può essere frazionaria.
    public var width: Double
    /// Da 0 a 1. A zero la fenditura è netta e tutti i pixel della finestra
    /// pesano uguale; a uno il peso segue una campana che si annulla ai bordi.
    /// È la differenza fra un taglio e una lunga esposizione.
    public var feather: Double
    /// Inclinazione in radianti. Zero è perpendicolare all'asse del tempo.
    public var angle: Double

    public init(width: Double = 4, feather: Double = 0, angle: Double = 0) {
        self.width = width
        self.feather = feather
        self.angle = angle
    }

    /// Quanti campioni prelevare lungo la larghezza. Uno per pixel non serve
    /// a niente sotto il pixel, e sopra i 64 il guadagno non si vede.
    var sampleCount: Int {
        max(1, min(64, Int(width.rounded(.up))))
    }
}

/// Il campionatore.
///
/// Tutta la morbidezza del risultato nasce qui, e non da un filtro applicato
/// dopo. Tre meccanismi distinti, cumulabili:
///
/// **Sub-pixel.** La fenditura vive a coordinate frazionarie e i pixel si
/// leggono per interpolazione bilineare. Senza questo, una deriva di 0,3 px
/// per fetta produce colonne ripetute a scatti invece di uno scorrimento.
///
/// **Sfumatura.** I pixel della finestra si mediano con pesi a campana invece
/// di essere copiati a peso pieno. È ciò che trasforma un taglio netto in uno
/// strisciato da lunga esposizione.
///
/// **Interpolazione temporale.** Due fotogrammi consecutivi si fondono quando
/// l'uscita chiede una colonna a metà fra l'uno e l'altro. Senza, la stessa
/// colonna viene ripetuta e nella striscia compaiono bande dure: è la causa
/// principale dell'aspetto meccanico.
public enum SlitSampler {

    /// Scrive una fetta nell'orientamento della striscia.
    ///
    /// - Parameters:
    ///   - a: fotogramma corrente.
    ///   - b: fotogramma successivo, se serve interpolare nel tempo.
    ///   - mix: da 0 (solo `a`) a 1 (solo `b`).
    ///   - centre: posizione della fenditura sull'asse trasversale, frazionaria.
    ///   - outCross: dimensione trasversale dell'uscita.
    ///   - outStep: quante colonne (o righe) produrre.
    ///   - gain: correzione di esposizione.
    ///   - out: buffer RGBA di `outStep * outCross` pixel.
    public static func slice(
        a: PixelSource,
        b: PixelSource? = nil,
        mix: Double = 0,
        axis: StripBuffer.Axis,
        centre: Double,
        kernel: SlitKernel,
        outCross: Int,
        outStep: Int,
        gain: Double = 1,
        into out: inout [UInt8]
    ) {
        if let b, mix > 0 {
            slice(frames: [a, b], weights: [1 - mix, mix], axis: axis, centre: centre,
                  kernel: kernel, outCross: outCross, outStep: outStep, gain: gain, into: &out)
        } else {
            slice(frames: [a], weights: [1], axis: axis, centre: centre,
                  kernel: kernel, outCross: outCross, outStep: outStep, gain: gain, into: &out)
        }
    }

    /// Come sopra, ma mediando un numero qualunque di fotogrammi.
    ///
    /// È qui che nasce la morbidezza vera. Fondere due fotogrammi consecutivi
    /// toglie le bande dure ma resta una dissolvenza fra due istanti: si vede
    /// il doppio contorno. Mediandone dodici con pesi a campana si ottiene una
    /// lunga esposizione sull'asse del tempo, e le transizioni diventano
    /// continue — è l'aspetto dei ritratti slit-scan in cui il volto si
    /// deforma senza mai mostrare un bordo.
    public static func slice(
        frames: [PixelSource],
        weights: [Double],
        axis: StripBuffer.Axis,
        centre: Double,
        kernel: SlitKernel,
        outCross: Int,
        outStep: Int,
        gain: Double = 1,
        into out: inout [UInt8]
    ) {
        guard outCross > 0, outStep > 0, !frames.isEmpty else { return }
        let w = weights.count == frames.count ? weights : [Double](repeating: 1, count: frames.count)
        guard w.reduce(0, +) > 0 else { return }
        sampleInto(&out, frames: frames, weights: w, axis: axis,
                   centre: centre, kernel: kernel, outCross: outCross, outStep: outStep, gain: gain)
    }

    /// Pesi a campana sull'asse del tempo.
    ///
    /// A sfumatura zero tutti i fotogrammi della finestra pesano uguale, che
    /// somiglia a un otturatore aperto e richiuso di colpo. Salendo, i
    /// fotogrammi ai bordi contano sempre meno e la transizione perde ogni
    /// stacco.
    public static func temporalWeights(count: Int, feather: Double) -> [Double] {
        guard count > 1 else { return [1] }
        let f = min(max(feather, 0), 1)
        guard f > 0 else { return [Double](repeating: 1, count: count) }
        return (0..<count).map { k in
            let t = Double(k) / Double(count - 1) * 2 - 1
            return 1 - f + f * exp(-4.5 * t * t)
        }
    }

    private static func sampleInto(
        _ out: inout [UInt8],
        frames: [PixelSource],
        weights: [Double],
        axis: StripBuffer.Axis,
        centre: Double,
        kernel: SlitKernel,
        outCross: Int,
        outStep: Int,
        gain: Double
    ) {
        let spatial = kernelWeights(kernel)
        let half = kernel.width / 2
        let tanAngle = tan(kernel.angle)
        let a = frames[0]

        out.withUnsafeMutableBufferPointer { dst in
            for i in 0..<outStep {
                // Posizione della sotto-fetta dentro la finestra: con outStep
                // maggiore di uno la finestra viene attraversata, non ripetuta.
                let within = outStep == 1 ? 0.0 : (Double(i) / Double(outStep - 1) - 0.5)
                let x0 = centre + within * kernel.width

                for c in 0..<outCross {
                    // Coordinata trasversale nel fotogramma, frazionaria.
                    let crossSpan = axis == .vertical ? Double(a.height) : Double(a.width)
                    let along = (Double(c) + 0.5) / Double(outCross) * crossSpan

                    // L'inclinazione sposta la fenditura in funzione della
                    // posizione lungo il taglio.
                    let shifted = x0 + (along - crossSpan / 2) * tanAngle

                    var r = 0.0, g = 0.0, bl = 0.0, wsum = 0.0
                    for (k, kw) in spatial.enumerated() {
                        let t = spatial.count == 1 ? 0.0
                              : (Double(k) / Double(spatial.count - 1) - 0.5) * 2
                        let sx = shifted + t * half

                        // Ogni posizione della finestra spaziale viene letta
                        // su tutti i fotogrammi della finestra temporale.
                        for (fi, frame) in frames.enumerated() {
                            let weight = kw * weights[fi]
                            guard weight > 0 else { continue }
                            let px: (Double, Double, Double) = axis == .vertical
                                ? bilinear(frame, sx, along)
                                : bilinear(frame, along, sx)
                            r += px.0 * weight; g += px.1 * weight; bl += px.2 * weight
                            wsum += weight
                        }
                    }
                    if wsum > 0 { r /= wsum; g /= wsum; bl /= wsum }

                    let index = (axis == .vertical ? (c * outStep + i) : (i * outCross + c)) * 4
                    dst[index]     = clamp8(r * gain)
                    dst[index + 1] = clamp8(g * gain)
                    dst[index + 2] = clamp8(bl * gain)
                    dst[index + 3] = 255
                }
            }
        }
    }

    /// Profilo dei pesi lungo la larghezza della fenditura.
    ///
    /// A sfumatura zero è rettangolare — ogni pixel pesa uguale, che è il
    /// comportamento di un taglio. Crescendo diventa una campana: i bordi
    /// contano sempre meno, e il risultato somiglia a un'esposizione lunga.
    static func kernelWeights(_ kernel: SlitKernel) -> [Double] {
        let n = kernel.sampleCount
        guard n > 1, kernel.feather > 0 else { return [Double](repeating: 1, count: n) }
        let f = min(max(kernel.feather, 0), 1)
        return (0..<n).map { k in
            let t = Double(k) / Double(n - 1) * 2 - 1        // da -1 a 1
            let bell = exp(-4.5 * t * t)
            return 1 - f + f * bell
        }
    }

    // MARK: - Lettura di un pixel

    /// Lettura bilineare. Restituisce RGB, convertendo da BGRA.
    static func bilinear(_ s: PixelSource, _ x: Double, _ y: Double) -> (Double, Double, Double) {
        let cx = min(max(x - 0.5, 0), Double(s.width - 1))
        let cy = min(max(y - 0.5, 0), Double(s.height - 1))
        let x0 = Int(cx), y0 = Int(cy)
        let x1 = min(x0 + 1, s.width - 1)
        let y1 = min(y0 + 1, s.height - 1)
        let fx = cx - Double(x0)
        let fy = cy - Double(y0)

        @inline(__always)
        func at(_ px: Int, _ py: Int) -> (Double, Double, Double) {
            let p = s.base + py * s.stride + px * 4
            return (Double(p[2]), Double(p[1]), Double(p[0]))   // BGRA -> RGB
        }

        let p00 = at(x0, y0), p10 = at(x1, y0)
        let p01 = at(x0, y1), p11 = at(x1, y1)

        @inline(__always)
        func mix4(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
            let top = a + (b - a) * fx
            let bottom = c + (d - c) * fx
            return top + (bottom - top) * fy
        }
        return (mix4(p00.0, p10.0, p01.0, p11.0),
                mix4(p00.1, p10.1, p01.1, p11.1),
                mix4(p00.2, p10.2, p01.2, p11.2))
    }

    @inline(__always)
    private static func clamp8(_ v: Double) -> UInt8 {
        v <= 0 ? 0 : (v >= 255 ? 255 : UInt8(v))
    }
}
