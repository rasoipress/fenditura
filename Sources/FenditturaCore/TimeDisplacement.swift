import Foundation

/// Tela per il time displacement.
///
/// Qui l'uscita ha le dimensioni di un fotogramma e ogni colonna resta al
/// proprio posto: cambia soltanto l'istante da cui viene. Il soggetto non
/// scorre via, si deforma — è l'effetto dei ritratti smaterializzati.
///
/// La conseguenza pratica è opposta a quella della strisciata: l'immagine è
/// piccola e nota fin dall'inizio, quindi sta in memoria e si vede tutta
/// mentre si forma. Niente piastrelle, niente scrittura a flusso, nessun
/// limite di lunghezza da sorvegliare.
///
/// Il riempimento avviene in una passata sola. Non serve saltare avanti e
/// indietro nel video: per ogni fotogramma che arriva si scrivono le colonne
/// che gli competono, e quando il filmato finisce la tela è piena.
public final class TimeDisplacementCanvas {

    public let width: Int
    public let height: Int
    /// Su quale asse corre il tempo.
    public let axis: StripBuffer.Axis
    public private(set) var pixels: [UInt8]
    /// Quali colonne (o righe) sono già state scritte.
    private var filled: [Bool]

    public init(width: Int, height: Int, axis: StripBuffer.Axis) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.axis = axis
        self.pixels = [UInt8](repeating: 0, count: self.width * self.height * 4)
        self.filled = [Bool](repeating: false, count: axis == .vertical ? self.width : self.height)
    }

    /// Quante colonne compongono l'asse del tempo.
    public var timeSpan: Int { axis == .vertical ? width : height }

    /// Intervallo di colonne che compete a un istante.
    ///
    /// - Parameters:
    ///   - progress: posizione nel filmato, da 0 a 1.
    ///   - nextProgress: posizione del fotogramma successivo, per sapere dove
    ///     finisce la competenza di questo.
    ///   - spread: quanta parte dell'immagine copre il filmato intero.
    ///   - reversed: il tempo scorre da destra a sinistra.
    public func range(progress: Double, nextProgress: Double,
                      spread: Double, reversed: Bool) -> Range<Int>? {
        let span = Double(timeSpan)
        let s = min(max(spread, 0.01), 1)
        func map(_ p: Double) -> Double {
            let q = min(max(p / s, 0), 1)
            return (reversed ? 1 - q : q) * span
        }
        var a = map(progress)
        var b = map(nextProgress)
        if a > b { swap(&a, &b) }
        let lo = max(0, Int(a.rounded(.down)))
        let hi = min(timeSpan, max(lo + 1, Int(b.rounded(.up))))
        return lo < hi ? lo..<hi : nil
    }

    /// Scrive una colonna (o riga) già campionata.
    ///
    /// `line` contiene `crossSize` pixel RGBA, dove crossSize è l'altezza per
    /// l'asse verticale e la larghezza per quello orizzontale.
    public func write(line: [UInt8], at index: Int) {
        guard index >= 0, index < timeSpan else { return }
        switch axis {
        case .vertical:
            guard line.count >= height * 4 else { return }
            for y in 0..<height {
                let d = (y * width + index) * 4
                let s = y * 4
                pixels[d] = line[s]
                pixels[d + 1] = line[s + 1]
                pixels[d + 2] = line[s + 2]
                pixels[d + 3] = 255
            }
        case .horizontal:
            guard line.count >= width * 4 else { return }
            let d = index * width * 4
            pixels.replaceSubrange(d..<(d + width * 4), with: line[0..<(width * 4)])
        }
        filled[index] = true
    }

    public var filledCount: Int { filled.lazy.filter { $0 }.count }
    public var isComplete: Bool { filledCount == timeSpan }

    public func reset() {
        for i in pixels.indices { pixels[i] = 0 }
        for i in filled.indices { filled[i] = false }
    }

    /// Scrive la tela come PNG, passando dallo stesso scrittore incrementale
    /// della strisciata: qui non servirebbe, ma un solo percorso di
    /// salvataggio è un solo percorso da verificare.
    public func write(to url: URL) throws {
        let writer = try PNGStreamWriter(url: url, width: width, height: height)
        do {
            let rowBytes = width * 4
            let band = max(1, min(256, 24_000_000 / rowBytes))
            var y = 0
            while y < height {
                let rows = min(band, height - y)
                let start = y * rowBytes
                let block = Array(pixels[start..<(start + rows * rowBytes)])
                try writer.write(rows: block, rowCount: rows)
                y += rows
            }
            try writer.finish()
        } catch {
            writer.abort()
            throw error
        }
    }
}
