import Foundation

/// Accumulo della striscia in piastrelle.
///
/// La striscia non sta in un solo blocco di memoria — con un video lungo
/// arriva a centinaia di megabyte — quindi cresce a piastrelle di lunghezza
/// fissa.
///
/// Ogni piastrella porta con sé quanto è stata riempita **davvero**. Nella
/// versione precedente quel numero veniva dedotto, dando per scontato che
/// tutte le piastrelle tranne l'ultima fossero piene fino in fondo: vero solo
/// se la fetta in uscita divide esattamente la lunghezza della piastrella,
/// cioè per le potenze di due e per nient'altro. Con una fetta da 3 o da 24
/// pixel ogni piastrella chiudeva con una frangia mai disegnata, che finiva
/// nera dentro l'immagine salvata. Qui non è deducibile: è un campo.
public final class StripBuffer {

    /// Orientamento della fenditura.
    public enum Axis: String, Sendable, CaseIterable {
        /// Fenditura verticale, striscia che cresce in orizzontale.
        case vertical
        /// Fenditura orizzontale, striscia che cresce in verticale.
        case horizontal
    }

    public struct Tile {
        /// Pixel RGBA. Per l'asse verticale la riga è lunga `tileLength`,
        /// per quello orizzontale è lunga `cross`.
        public var pixels: [UInt8]
        /// Quanti pixel dell'asse lungo sono stati scritti in questa piastrella.
        public private(set) var fill: Int

        fileprivate mutating func advance(by n: Int) { fill += n }
        fileprivate init(capacity: Int) {
            pixels = [UInt8](repeating: 0, count: capacity)
            fill = 0
        }
    }

    public static let tileLength = 4096

    public let axis: Axis
    /// Dimensione trasversale dell'uscita, in pixel.
    public let cross: Int
    public private(set) var tiles: [Tile] = []
    /// Lunghezza accumulata sull'asse del tempo.
    public private(set) var length = 0

    private let bytesPerTile: Int

    public init(axis: Axis, cross: Int) {
        self.axis = axis
        self.cross = max(1, cross)
        self.bytesPerTile = Self.tileLength * self.cross * 4
    }

    /// Dimensioni dell'immagine risultante, specchiatura inclusa se richiesta.
    public func outputSize(mirrored: Bool) -> (width: Int, height: Int) {
        let long = length * (mirrored ? 2 : 1)
        switch axis {
        case .vertical: return (long, cross)
        case .horizontal: return (cross, long)
        }
    }

    /// Aggiunge una fetta larga `step` pixel sull'asse lungo.
    ///
    /// `slice` contiene `step * cross` pixel RGBA disposti nell'orientamento
    /// della striscia: per l'asse verticale righe da `step`, per quello
    /// orizzontale righe da `cross`.
    public func append(slice: [UInt8], step: Int) {
        guard step > 0, cross > 0 else { return }
        let expected = step * cross * 4
        guard slice.count >= expected else { return }

        if tiles.isEmpty || tiles[tiles.count - 1].fill + step > Self.tileLength {
            tiles.append(Tile(capacity: bytesPerTile))
        }
        let index = tiles.count - 1
        let at = tiles[index].fill

        switch axis {
        case .vertical:
            // La piastrella è larga tileLength: ogni riga della fetta va
            // copiata all'offset orizzontale della testa di scansione.
            let tileRow = Self.tileLength * 4
            let sliceRow = step * 4
            for y in 0..<cross {
                let dst = y * tileRow + at * 4
                let src = y * sliceRow
                tiles[index].pixels.replaceSubrange(dst..<(dst + sliceRow),
                                                    with: slice[src..<(src + sliceRow)])
            }
        case .horizontal:
            // La piastrella è larga cross: la fetta è un blocco contiguo.
            let dst = at * cross * 4
            tiles[index].pixels.replaceSubrange(dst..<(dst + expected),
                                                with: slice[0..<expected])
        }

        tiles[index].advance(by: step)
        length += step
    }

    public func reset() {
        tiles.removeAll()
        length = 0
    }

    /// Un tratto della striscia lungo l'asse del tempo, già ordinato secondo il
    /// verso di accumulo, con la coda specchiata se richiesta.
    public struct Run {
        public let tileIndex: Int
        public let count: Int
        public let reversed: Bool
    }

    public func runs(reversedOrder: Bool, mirrored: Bool) -> [Run] {
        var base: [Run] = []
        for (i, tile) in tiles.enumerated() where tile.fill > 0 {
            base.append(Run(tileIndex: i, count: tile.fill, reversed: false))
        }
        var sequence = base
        if reversedOrder {
            sequence = base.reversed().map { Run(tileIndex: $0.tileIndex, count: $0.count, reversed: true) }
        }
        guard mirrored else { return sequence }
        let back = sequence.reversed().map { Run(tileIndex: $0.tileIndex, count: $0.count, reversed: !$0.reversed) }
        return sequence + back
    }
}
