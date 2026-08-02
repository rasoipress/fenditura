import Foundation

/// Misura di quanto l'immagine si sposta sotto la fenditura.
///
/// È il cuore del programma. Se il soggetto si sposta di **d** pixel fra una
/// fetta e la successiva e la fetta è larga **s**, l'immagine finale è scalata
/// di **s / d** sull'asse lungo: con `s = 1` e `d = 8` esce schiacciata otto
/// volte, e nessuno stiramento in post la recupera, perché quell'informazione
/// non è mai stata campionata.
///
/// Il metodo: da ogni fotogramma si ricava un profilo di luminanza — una media
/// per colonna, o per riga — e lo si confronta con il precedente cercando lo
/// scorrimento che minimizza l'errore quadratico.
///
/// Un dettaglio che nella versione precedente era sbagliato e produceva un
/// numero errato di un fattore intero: il risultato va diviso per **quante
/// fette sono passate** fra i due profili confrontati, non per il passo di
/// campionamento. Sono due grandezze diverse, e coincidono solo per caso.
public final class MotionMeter {

    /// Larghezza del profilo di analisi. Più corto del fotogramma: la misura
    /// non ha bisogno di risoluzione piena e questo la rende molto più rapida.
    public static let profileSize = 208

    public private(set) var measured: Double?
    private var previous: [Float]?
    private var previousAtFrame = 0
    private var smoothed: Double?

    public init() {}

    public func reset() {
        previous = nil
        previousAtFrame = 0
        measured = nil
        smoothed = nil
    }

    /// Confronta il profilo con il precedente.
    ///
    /// - Parameters:
    ///   - profile: profilo di luminanza del fotogramma corrente.
    ///   - frameIndex: numero di fette catturate finora. Serve a sapere quante
    ///     ne sono passate dall'ultimo confronto.
    ///   - crossSize: dimensione reale dell'asse trasversale, in pixel della
    ///     sorgente, per riportare lo scorrimento dalla scala del profilo a
    ///     quella vera.
    @discardableResult
    public func submit(profile: [Float], frameIndex: Int, crossSize: Int) -> Double? {
        defer {
            previous = profile
            previousAtFrame = frameIndex
        }
        guard let prev = previous, prev.count == profile.count, profile.count > 8 else {
            return measured
        }

        let elapsed = max(1, frameIndex - previousAtFrame)
        let n = profile.count
        let range = min(30, n / 4)
        var best = 0
        var bestError = Double.greatestFiniteMagnitude

        for shift in -range...range {
            var error = 0.0
            var count = 0
            var i = range
            while i < n - range {
                let j = i + shift
                if j >= 0 && j < n {
                    let d = Double(profile[i] - prev[j])
                    error += d * d
                    count += 1
                }
                i += 1
            }
            if count > 0 {
                error /= Double(count)
                if error < bestError {
                    bestError = error
                    best = shift
                }
            }
        }

        let perFrame = (Double(abs(best)) * (Double(crossSize) / Double(n))) / Double(elapsed)
        smoothed = smoothed == nil ? perFrame : smoothed! * 0.72 + perFrame * 0.28
        measured = smoothed
        return measured
    }

    // MARK: - Verdetto

    public enum Verdict: Equatable, Sendable {
        case unknown
        /// L'immagine è ferma sotto il taglio: la camera insegue il soggetto.
        case still
        /// Il moto supera la fenditura più larga possibile.
        case tooFast(perFrame: Double)
        case stretched(times: Double, suggestedWidth: Int)
        case squashed(times: Double, suggestedWidth: Int)
        case correct
    }

    public func verdict(sliceWidth: Int, maxWidth: Int) -> Verdict {
        guard let m = measured else { return .unknown }
        if m < 0.35 { return .still }
        if m > Double(maxWidth) { return .tooFast(perFrame: m) }
        let ratio = Double(sliceWidth) / max(m, 0.001)
        let suggested = min(max(Int(m.rounded()), 1), maxWidth)
        if ratio > 1.6 { return .stretched(times: ratio, suggestedWidth: suggested) }
        if ratio < 0.62 { return .squashed(times: 1 / ratio, suggestedWidth: suggested) }
        return .correct
    }

    /// Larghezza di fetta che darebbe proporzioni corrette.
    public func suggestedWidth(maxWidth: Int) -> Int? {
        guard let m = measured, m >= 0.35 else { return nil }
        return min(max(Int(m.rounded()), 1), maxWidth)
    }
}
