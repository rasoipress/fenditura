import Foundation

/// Dove sta la fenditura, fetta per fetta.
///
/// La deriva lineare è il caso particolare in cui la traiettoria è una retta.
/// Tenerla come caso di una funzione generale, invece che come unico
/// comportamento possibile, permette di seguire un soggetto che accelera o
/// che torna indietro senza cambiare niente nel motore di scansione.
public enum Trajectory: Equatable, Sendable {

    /// Ferma alla posizione iniziale.
    case fixed(position: Double)

    /// Scorre di `drift` pixel per fetta catturata.
    case linear(position: Double, drift: Double)

    /// Interpolata fra punti dichiarati.
    ///
    /// Ogni chiave dice: alla fetta *n*, la fenditura sta a *position* (da 0 a 1
    /// dell'asse trasversale). Fra due chiavi l'app interpola.
    case keyframed(keys: [Keyframe], easing: Easing)

    public struct Keyframe: Equatable, Sendable, Codable {
        public var slice: Int
        public var position: Double
        public init(slice: Int, position: Double) {
            self.slice = slice
            self.position = max(0, min(1, position))
        }
    }

    public enum Easing: String, Equatable, Sendable, Codable, CaseIterable {
        /// Segmenti dritti: la velocità cambia di colpo a ogni chiave.
        case linear
        /// Raccordo morbido in entrata e in uscita da ogni chiave. È quasi
        /// sempre quello che si vuole: un cambio di direzione netto si vede
        /// nella striscia come una piega.
        case smooth

        func apply(_ t: Double) -> Double {
            switch self {
            case .linear: return t
            case .smooth: return t * t * (3 - 2 * t)
            }
        }
    }

    /// Posizione della fenditura, in pixel della sorgente, alla fetta indicata.
    public func position(atSlice slice: Int, crossSize: Int) -> Double {
        let cross = Double(max(crossSize, 1))
        switch self {
        case .fixed(let p):
            return p * cross
        case .linear(let p, let drift):
            return p * cross + drift * Double(slice)
        case .keyframed(let keys, let easing):
            return Self.interpolate(keys: keys, easing: easing, slice: slice) * cross
        }
    }

    static func interpolate(keys: [Keyframe], easing: Easing, slice: Int) -> Double {
        guard !keys.isEmpty else { return 0.5 }
        let sorted = keys.sorted { $0.slice < $1.slice }
        if slice <= sorted[0].slice { return sorted[0].position }
        if let last = sorted.last, slice >= last.slice { return last.position }
        for i in 1..<sorted.count where slice <= sorted[i].slice {
            let a = sorted[i - 1]
            let b = sorted[i]
            let span = Double(b.slice - a.slice)
            guard span > 0 else { return b.position }
            let t = easing.apply(Double(slice - a.slice) / span)
            return a.position + (b.position - a.position) * t
        }
        return sorted[sorted.count - 1].position
    }
}

// Codable a mano: un enum con valori associati non lo sintetizza in una forma
// leggibile, e questo finisce in un file di impostazioni che l'utente apre.
extension Trajectory: Codable {
    private enum Kind: String, Codable { case fixed, linear, keyframed }
    private enum CodingKeys: String, CodingKey { case kind, position, drift, keys, easing }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fixed(let p):
            try c.encode(Kind.fixed, forKey: .kind)
            try c.encode(p, forKey: .position)
        case .linear(let p, let d):
            try c.encode(Kind.linear, forKey: .kind)
            try c.encode(p, forKey: .position)
            try c.encode(d, forKey: .drift)
        case .keyframed(let keys, let easing):
            try c.encode(Kind.keyframed, forKey: .kind)
            try c.encode(keys, forKey: .keys)
            try c.encode(easing, forKey: .easing)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .fixed:
            self = .fixed(position: try c.decode(Double.self, forKey: .position))
        case .linear:
            self = .linear(position: try c.decode(Double.self, forKey: .position),
                           drift: try c.decode(Double.self, forKey: .drift))
        case .keyframed:
            self = .keyframed(keys: try c.decode([Keyframe].self, forKey: .keys),
                              easing: try c.decode(Easing.self, forKey: .easing))
        }
    }
}

/// Cosa produce la scansione.
///
/// Le quattro modalità non sono quattro algoritmi: sono quattro modi di
/// rispondere alle stesse due domande per ogni colonna dell'uscita — da quale
/// istante, e da quale posizione nel fotogramma.
public enum ScanMode: String, Equatable, Sendable, Codable, CaseIterable {

    /// Fette accodate: l'immagine cresce senza limite sull'asse del tempo.
    /// L'istante avanza con la colonna, la posizione la dà la traiettoria.
    case strip

    /// L'uscita è grande come un fotogramma e ogni colonna viene da un istante
    /// diverso, restando al proprio posto. Il soggetto non scorre via: si
    /// deforma. È l'effetto dei ritratti smaterializzati.
    case timeDisplacement

    /// Per soggetti che ruotano su sé stessi: la fenditura resta ferma e la
    /// superficie cilindrica si srotola in un piano.
    case rollout

    /// Più strisce nella stessa passata, da fenditure a posizioni diverse.
    /// Serve a decidere dove mettere il taglio senza riscansionare.
    case multiStrip

    public var label: String {
        switch self {
        case .strip: return "Strisciata"
        case .timeDisplacement: return "Time displacement"
        case .rollout: return "Srotolamento"
        case .multiStrip: return "Strisce multiple"
        }
    }

    /// Le modalità a uscita illimitata scrivono su disco a flusso; quelle a
    /// uscita fissa stanno in memoria e si possono rivedere per intero.
    public var hasUnboundedOutput: Bool {
        switch self {
        case .strip, .rollout, .multiStrip: return true
        case .timeDisplacement: return false
        }
    }
}
