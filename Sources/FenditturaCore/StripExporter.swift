import Foundation

/// Scrive la striscia su disco passando dallo scrittore PNG incrementale.
///
/// Le due strade non sono simmetriche, e la ragione è nella forma del PNG, che
/// si scrive per righe.
///
/// Con la fenditura verticale la striscia cresce in orizzontale: ogni riga del
/// PNG attraversa **tutte** le piastrelle, quindi va ricomposta pezzo per
/// pezzo. Con la fenditura orizzontale la striscia cresce in verticale e le
/// righe del PNG sono già consecutive dentro ogni piastrella: si copiano.
public enum StripExporter {

    public struct Progress {
        public let rowsWritten: Int
        public let rowsTotal: Int
        public var fraction: Double { rowsTotal > 0 ? Double(rowsWritten) / Double(rowsTotal) : 0 }
    }

    public enum Failure: Error, CustomStringConvertible {
        case empty
        case cancelled
        case unsupported(String)
        public var description: String {
            switch self {
            case .empty: return "non c'è ancora niente da salvare"
            case .cancelled: return "annullato"
            case .unsupported(let why): return why
            }
        }
    }

    /// - Parameters:
    ///   - shouldContinue: interrogata a ogni banda; restituendo `false` il
    ///     salvataggio si interrompe e il file parziale viene rimosso.
    public static func write(
        strip: StripBuffer,
        to url: URL,
        reversedOrder: Bool,
        mirrored: Bool,
        onProgress: ((Progress) -> Void)? = nil,
        shouldContinue: (() -> Bool)? = nil
    ) throws {
        guard strip.length > 0 else { throw Failure.empty }

        let size = strip.outputSize(mirrored: mirrored)
        let runs = strip.runs(reversedOrder: reversedOrder, mirrored: mirrored)
        let writer = try PNGStreamWriter(url: url, width: size.width, height: size.height)

        do {
            switch strip.axis {
            case .vertical:
                try writeAcross(strip: strip, runs: runs, size: size, writer: writer,
                                onProgress: onProgress, shouldContinue: shouldContinue)
            case .horizontal:
                try writeAlong(strip: strip, runs: runs, size: size, writer: writer,
                               onProgress: onProgress, shouldContinue: shouldContinue)
            }
            try writer.finish()
        } catch {
            writer.abort()
            throw error
        }
    }

    /// Più strisce impilate in un'immagine sola, separate da una banda nera.
    ///
    /// Serve alla modalità a fenditure multiple: si guardano affiancate le
    /// stesse cose viste da tagli diversi, e si decide dove mettere la
    /// fenditura senza dover riscansionare il video una volta per ipotesi.
    public static func writeStacked(
        strips: [StripBuffer],
        to url: URL,
        reversedOrder: Bool,
        mirrored: Bool,
        gap: Int = 12,
        onProgress: ((Progress) -> Void)? = nil,
        shouldContinue: (() -> Bool)? = nil
    ) throws {
        guard let first = strips.first, first.length > 0 else { throw Failure.empty }
        guard first.axis == .vertical else {
            // Con la fenditura orizzontale le strisce crescono in verticale e
            // andrebbero affiancate, non impilate. Non è ancora previsto, e
            // dirlo è meglio che produrre un'immagine sbagliata.
            throw Failure.unsupported("le strisce multiple richiedono la fenditura verticale")
        }

        let unit = first.outputSize(mirrored: mirrored)
        let count = strips.count
        let total = unit.height * count + gap * (count - 1)
        let writer = try PNGStreamWriter(url: url, width: unit.width, height: total)

        do {
            let rowBytes = unit.width * 4
            let blank = [UInt8](repeating: 0, count: rowBytes * gap)
            var written = 0

            for (i, strip) in strips.enumerated() {
                if shouldContinue?() == false { throw Failure.cancelled }
                let runs = strip.runs(reversedOrder: reversedOrder, mirrored: mirrored)
                try writeAcross(strip: strip, runs: runs,
                                size: (width: unit.width, height: unit.height),
                                writer: writer,
                                onProgress: { p in
                                    onProgress?(Progress(rowsWritten: written + p.rowsWritten,
                                                         rowsTotal: total))
                                },
                                shouldContinue: shouldContinue)
                written += unit.height
                if i < count - 1 {
                    try writer.write(rows: blank, rowCount: gap)
                    written += gap
                }
            }
            try writer.finish()
        } catch {
            writer.abort()
            throw error
        }
    }

    // MARK: - Striscia orizzontale

    private static func writeAcross(
        strip: StripBuffer,
        runs: [StripBuffer.Run],
        size: (width: Int, height: Int),
        writer: PNGStreamWriter,
        onProgress: ((Progress) -> Void)?,
        shouldContinue: (() -> Bool)?
    ) throws {
        let rowBytes = size.width * 4
        let tileRowBytes = StripBuffer.tileLength * 4
        // Una banda da circa 24 MB: abbastanza da ammortizzare le chiamate,
        // poca abbastanza da non contare come "immagine intera in memoria".
        let band = max(1, min(256, 24_000_000 / max(rowBytes, 1)))
        var out = [UInt8](repeating: 0, count: rowBytes * band)

        var y = 0
        while y < size.height {
            if shouldContinue?() == false { throw Failure.cancelled }
            let rows = min(band, size.height - y)

            var x = 0
            for run in runs {
                let tile = strip.tiles[run.tileIndex]
                let runBytes = run.count * 4
                for r in 0..<rows {
                    let srcRow = (y + r) * tileRowBytes
                    let dst = r * rowBytes + x * 4
                    if !run.reversed {
                        tile.pixels.withUnsafeBufferPointer { src in
                            out.withUnsafeMutableBufferPointer { dstBuf in
                                let s = src.baseAddress! + srcRow
                                let d = dstBuf.baseAddress! + dst
                                d.update(from: s, count: runBytes)
                            }
                        }
                    } else {
                        for c in 0..<run.count {
                            let s = srcRow + (run.count - 1 - c) * 4
                            let d = dst + c * 4
                            out[d] = tile.pixels[s]
                            out[d + 1] = tile.pixels[s + 1]
                            out[d + 2] = tile.pixels[s + 2]
                            out[d + 3] = tile.pixels[s + 3]
                        }
                    }
                }
                x += run.count
            }

            try writer.write(rows: out, rowCount: rows)
            y += rows
            onProgress?(Progress(rowsWritten: y, rowsTotal: size.height))
        }
    }

    // MARK: - Striscia verticale

    private static func writeAlong(
        strip: StripBuffer,
        runs: [StripBuffer.Run],
        size: (width: Int, height: Int),
        writer: PNGStreamWriter,
        onProgress: ((Progress) -> Void)?,
        shouldContinue: (() -> Bool)?
    ) throws {
        let rowBytes = size.width * 4
        let chunk = max(1, min(2048, 24_000_000 / max(rowBytes, 1)))
        var done = 0

        for run in runs {
            let tile = strip.tiles[run.tileIndex]
            if !run.reversed {
                var off = 0
                while off < run.count {
                    if shouldContinue?() == false { throw Failure.cancelled }
                    let n = min(chunk, run.count - off)
                    let start = off * rowBytes
                    let block = Array(tile.pixels[start..<(start + n * rowBytes)])
                    try writer.write(rows: block, rowCount: n)
                    off += n
                    done += n
                    onProgress?(Progress(rowsWritten: done, rowsTotal: size.height))
                }
            } else {
                var off = run.count
                while off > 0 {
                    if shouldContinue?() == false { throw Failure.cancelled }
                    let n = min(chunk, off)
                    let start = (off - n) * rowBytes
                    let source = Array(tile.pixels[start..<(start + n * rowBytes)])
                    var block = [UInt8](repeating: 0, count: n * rowBytes)
                    for r in 0..<n {
                        let s = (n - 1 - r) * rowBytes
                        let d = r * rowBytes
                        block.replaceSubrange(d..<(d + rowBytes), with: source[s..<(s + rowBytes)])
                    }
                    try writer.write(rows: block, rowCount: n)
                    off -= n
                    done += n
                    onProgress?(Progress(rowsWritten: done, rowsTotal: size.height))
                }
            }
        }
    }
}
