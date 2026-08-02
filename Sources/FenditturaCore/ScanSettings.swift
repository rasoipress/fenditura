import Foundation

/// Impostazioni della scansione.
///
/// Ogni valore ha un intervallo dichiarato e `clamped()` lo riporta dentro.
/// Serve perché queste impostazioni si salvano e si ricaricano da JSON, che
/// l'utente può modificare a mano o che può arrivare da una versione diversa:
/// un valore assurdo non deve poter mettere la scansione in uno stato
/// impossibile.
public struct ScanSettings: Codable, Equatable, Sendable {

    public enum Limits {
        public static let position = 0.0...1.0
        public static let slitWidth = 0.25...256.0
        public static let feather = 0.0...1.0
        public static let angle = -1.2...1.2          // radianti, circa ±69°
        public static let drift = -32.0...32.0
        public static let scale = 0.1...1.0
        public static let step = 1...16
        public static let maxLength = 1000...2_000_000
        public static let stripCount = 2...8
        public static let spread = 0.05...1.0
        public static let temporalWindow = 1...24
    }

    // MARK: - Cosa produrre

    public var mode: ScanMode = .strip

    /// Dove sta la fenditura, fetta per fetta.
    public var trajectory: Trajectory = .linear(position: 0.5, drift: 0)

    /// Forma della fenditura: larghezza, sfumatura, inclinazione.
    public var kernel = SlitKernel(width: 4, feather: 0, angle: 0)

    /// Su quanti fotogrammi consecutivi si media ogni colonna.
    ///
    /// A uno la colonna viene da un istante solo. A due si fondono due
    /// fotogrammi, che toglie le bande dure ma lascia un doppio contorno. Da
    /// otto in su diventa una lunga esposizione sull'asse del tempo, ed è ciò
    /// che rende continue le transizioni nei ritratti slit-scan.
    public var temporalWindow: Int = 2

    /// Forma dei pesi sulla finestra temporale. A zero l'otturatore si apre e
    /// si chiude di colpo; a uno i fotogrammi ai bordi svaniscono.
    public var temporalFeather: Double = 0.6

    // MARK: - Geometria dell'uscita

    public var axis: StripBuffer.Axis = .vertical
    public var reversed: Bool = false
    public var mirrored: Bool = false
    public var scale: Double = 1.0

    // MARK: - Campionamento

    /// Una fetta ogni N fotogrammi.
    public var step: Int = 1
    public var maxLength: Int = 120_000
    public var stabiliseExposure: Bool = false

    // MARK: - Parametri delle singole modalità

    /// Quante strisce affiancare, in modalità a strisce multiple.
    public var stripCount: Int = 3
    /// Quanto della larghezza del fotogramma coprono le fenditure multiple.
    public var stripSpread: Double = 0.6
    /// Porzione della durata del video spalmata sull'asse orizzontale, in
    /// time displacement. A uno l'immagine copre tutto il filmato.
    public var timeSpread: Double = 1.0

    public init() {}

    // MARK: - Comodità

    /// Posizione della fenditura come frazione, indipendente dalla traiettoria.
    public var basePosition: Double {
        get {
            switch trajectory {
            case .fixed(let p): return p
            case .linear(let p, _): return p
            case .keyframed(let keys, _): return keys.first?.position ?? 0.5
            }
        }
        set {
            switch trajectory {
            case .fixed: trajectory = .fixed(position: newValue)
            case .linear(_, let d): trajectory = .linear(position: newValue, drift: d)
            case .keyframed: break   // con i fotogrammi chiave la posizione la danno le chiavi
            }
        }
    }

    public var drift: Double {
        get { if case .linear(_, let d) = trajectory { return d }; return 0 }
        set {
            let p = basePosition
            trajectory = newValue == 0 ? .fixed(position: p) : .linear(position: p, drift: newValue)
        }
    }

    // MARK: - Limiti

    public func clamped() -> ScanSettings {
        var s = self
        s.kernel.width = Self.clamp(kernel.width, Limits.slitWidth, 4)
        s.kernel.feather = Self.clamp(kernel.feather, Limits.feather, 0)
        s.kernel.angle = Self.clamp(kernel.angle, Limits.angle, 0)
        s.scale = Self.clamp(scale, Limits.scale, 1)
        s.step = Self.clamp(step, Limits.step, 1)
        s.maxLength = Self.clamp(maxLength, Limits.maxLength, 120_000)
        s.stripCount = Self.clamp(stripCount, Limits.stripCount, 3)
        s.stripSpread = Self.clamp(stripSpread, Limits.spread, 0.6)
        s.timeSpread = Self.clamp(timeSpread, 0.01...1.0, 1)
        s.temporalWindow = Self.clamp(temporalWindow, Limits.temporalWindow, 2)
        s.temporalFeather = Self.clamp(temporalFeather, Limits.feather, 0.6)
        s.trajectory = Self.clamp(trajectory)
        // Lo srotolamento vuole la fenditura ferma: una deriva lo
        // trasformerebbe in una strisciata storta senza dirlo.
        if s.mode == .rollout, case .linear(let p, _) = s.trajectory {
            s.trajectory = .fixed(position: p)
        }
        return s
    }

    private static func clamp(_ t: Trajectory) -> Trajectory {
        switch t {
        case .fixed(let p):
            return .fixed(position: clamp(p, Limits.position, 0.5))
        case .linear(let p, let d):
            return .linear(position: clamp(p, Limits.position, 0.5),
                           drift: clamp(d, Limits.drift, 0))
        case .keyframed(let keys, let easing):
            let valid = keys
                .filter { $0.slice >= 0 && $0.position.isFinite }
                .map { Trajectory.Keyframe(slice: $0.slice, position: clamp($0.position, Limits.position, 0.5)) }
            return valid.isEmpty ? .fixed(position: 0.5) : .keyframed(keys: valid, easing: easing)
        }
    }

    private static func clamp(_ v: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        guard v.isFinite else { return fallback }
        return Swift.min(Swift.max(v, range.lowerBound), range.upperBound)
    }

    private static func clamp(_ v: Int, _ range: ClosedRange<Int>, _ fallback: Int) -> Int {
        Swift.min(Swift.max(v, range.lowerBound), range.upperBound)
    }

    // MARK: - Salvataggio

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func from(jsonData data: Data) throws -> ScanSettings {
        try JSONDecoder().decode(ScanSettings.self, from: data).clamped()
    }
}

extension StripBuffer.Axis: Codable {}

extension SlitKernel: Codable {
    enum CodingKeys: String, CodingKey { case width, feather, angle }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(width: try c.decode(Double.self, forKey: .width),
                  feather: try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0,
                  angle: try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width)
        try c.encode(feather, forKey: .feather)
        try c.encode(angle, forKey: .angle)
    }
}
