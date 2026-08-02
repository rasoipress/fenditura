import XCTest
import AppKit
import CoreGraphics
import ImageIO
@testable import FenditturaCore

/// Le stesse verifiche che nella versione precedente hanno trovato i difetti
/// seri. Nessuna di queste ha bisogno di aprire una finestra: girano in
/// qualche secondo con `swift test`, ed è il motivo per cui il nucleo è
/// separato dall'interfaccia.
final class FenditturaCoreTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fenditura-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // Rilettura con un decodificatore indipendente: se il PNG lo apre AppKit,
    // lo apre qualunque programma.
    /// Rilettura con un decodificatore indipendente, disegnando in un contesto
    /// dello spazio del dispositivo.
    ///
    /// `NSBitmapImageRep.colorAt` passa per la gestione del colore e restituisce
    /// componenti già convertite: su un PNG senza profilo i valori tornano
    /// spostati di qualche unità, e il confronto pixel a pixel fallisce per un
    /// motivo che non ha niente a che vedere con lo scrittore.
    private func readPNG(_ url: URL) throws -> (w: Int, h: Int, pixels: [UInt8]) {
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "test", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "PNG illeggibile"])
        }
        let w = cg.width
        let h = cg.height
        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (w, h, out)
    }

    // MARK: - Scrittore PNG

    func testPNGRoundTrip() throws {
        let w = 600, h = 61
        let url = tmp.appendingPathComponent("writer.png")
        let writer = try PNGStreamWriter(url: url, width: w, height: h)

        var expected = [UInt8](repeating: 0, count: w * h * 4)
        var y = 0
        while y < h {
            let n = min(7, h - y)
            var block = [UInt8](repeating: 0, count: w * 4 * n)
            for r in 0..<n {
                for x in 0..<w {
                    let v: [UInt8] = [
                        UInt8((x * 7 + (y + r) * 13) & 255),
                        UInt8((x ^ (y + r)) & 255),
                        UInt8((x * 3) & 255),
                        255
                    ]
                    let o = (r * w + x) * 4
                    block[o] = v[0]; block[o + 1] = v[1]; block[o + 2] = v[2]; block[o + 3] = v[3]
                    let e = ((y + r) * w + x) * 4
                    expected[e] = v[0]; expected[e + 1] = v[1]; expected[e + 2] = v[2]; expected[e + 3] = v[3]
                }
            }
            try writer.write(rows: block, rowCount: n)
            y += n
        }
        try writer.finish()

        let got = try readPNG(url)
        XCTAssertEqual(got.w, w, "larghezza riletta")
        XCTAssertEqual(got.h, h, "altezza riletta")

        var wrong = 0
        for _ in 0..<3000 {
            let px = Int.random(in: 0..<w)
            let py = Int.random(in: 0..<h)
            let o = (py * w + px) * 4
            for c in 0..<3 where got.pixels[o + c] != expected[o + c] { wrong += 1 }
        }
        XCTAssertEqual(wrong, 0, "pixel a caso identici all'originale")
    }

    func testPNGShortIsStillReadable() throws {
        let url = tmp.appendingPathComponent("short.png")
        let writer = try PNGStreamWriter(url: url, width: 32, height: 10)
        try writer.write(rows: [UInt8](repeating: 200, count: 32 * 4 * 3), rowCount: 3)
        try writer.finish()
        let got = try readPNG(url)
        XCTAssertEqual(got.h, 10, "un PNG con righe mancanti resta leggibile")
    }

    func testPNGAbortRemovesFile() throws {
        let url = tmp.appendingPathComponent("aborted.png")
        let writer = try PNGStreamWriter(url: url, width: 32, height: 5000)
        try writer.write(rows: [UInt8](repeating: 9, count: 32 * 4 * 2), rowCount: 2)
        writer.abort()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "il file annullato non deve restare sul disco")
    }

    func testPNGRejectsInvalidSize() {
        XCTAssertThrowsError(try PNGStreamWriter(url: tmp.appendingPathComponent("x.png"), width: 0, height: 10))
    }

    // MARK: - Misura del moto

    /// Profilo sintetico non periodico, così la correlazione ha un minimo solo.
    private func profile(offset: Int, size: Int = MotionMeter.profileSize) -> [Float] {
        (0..<size).map { i in
            let x = Double(i + offset)
            return Float(40 + 200 * (0.5 + 0.5 * sin(x * 0.11) * cos(x * 0.023)))
        }
    }

    /// Il misuratore deve restituire lo spostamento **per fetta catturata**,
    /// qualunque sia l'intervallo fra due misure. È esattamente il punto in cui
    /// la versione precedente sbagliava di un fattore intero: divideva per il
    /// passo di campionamento invece che per le fette trascorse.
    func testMotionMatchesKnownShift() {
        // Il profilo copre `crossSize` pixel reali in `profileSize` campioni:
        // tenendoli uguali, uno scorrimento di k campioni vale k pixel.
        let cross = MotionMeter.profileSize

        for (perSlice, slicesBetweenMeasures) in [(6, 1), (6, 2), (12, 1), (3, 4)] {
            let meter = MotionMeter()
            var slice = 0
            var offset = 0
            for _ in 0..<40 {
                meter.submit(profile: profile(offset: offset), frameIndex: slice, crossSize: cross)
                // fra una misura e la successiva passano più fette, e
                // l'immagine avanza di `perSlice` per ognuna
                slice += slicesBetweenMeasures
                offset += perSlice * slicesBetweenMeasures
            }
            let want = Double(perSlice)
            XCTAssertNotNil(meter.measured, "la misura deve esistere")
            if let got = meter.measured {
                XCTAssertEqual(got, want, accuracy: max(1.0, want * 0.2),
                               "\(perSlice) px per fetta, misurato ogni \(slicesBetweenMeasures): atteso \(want)")
            }
        }
    }

    func testMotionVerdicts() {
        let meter = MotionMeter()
        var offset = 0
        for f in 0..<30 {
            meter.submit(profile: profile(offset: offset), frameIndex: f, crossSize: MotionMeter.profileSize)
            offset += 10
        }
        XCTAssertEqual(meter.verdict(sliceWidth: 10, maxWidth: 96), .correct)
        if case .stretched = meter.verdict(sliceWidth: 40, maxWidth: 96) {} else {
            XCTFail("una fetta molto più larga del moto deve risultare stirata")
        }
        if case .squashed = meter.verdict(sliceWidth: 2, maxWidth: 96) {} else {
            XCTFail("una fetta molto più stretta del moto deve risultare schiacciata")
        }
        XCTAssertEqual(meter.suggestedWidth(maxWidth: 96), 10)
    }

    func testMotionStillImage() {
        let meter = MotionMeter()
        for f in 0..<20 {
            meter.submit(profile: profile(offset: 0), frameIndex: f, crossSize: MotionMeter.profileSize)
        }
        XCTAssertEqual(meter.verdict(sliceWidth: 4, maxWidth: 96), .still,
                       "immagine ferma sotto il taglio")
    }

    // MARK: - Piastrelle

    /// Una fetta che non divide 4096 lascia una frangia in fondo a ogni
    /// piastrella. È il difetto che nella versione precedente finiva nero
    /// dentro l'immagine salvata, e che nessuna prova coglieva perché tutte
    /// restavano dentro la prima piastrella.
    func testTilesWithNonDividingSlice() throws {
        for (axis, width) in [(StripBuffer.Axis.vertical, 24),
                              (StripBuffer.Axis.vertical, 5),
                              (StripBuffer.Axis.horizontal, 24)] {
            for mirrored in [false, true] {
                let cross = 24
                let strip = StripBuffer(axis: axis, cross: cross)
                let slice = [UInt8](repeating: 180, count: width * cross * 4).enumerated().map { i, v -> UInt8 in
                    i % 4 == 3 ? 255 : v
                }
                let needed = (4096 / width + 40)
                for _ in 0..<needed { strip.append(slice: slice, step: width) }

                XCTAssertGreaterThan(strip.length, 4096, "la striscia deve superare una piastrella")
                XCTAssertGreaterThan(strip.tiles.count, 1, "devono esserci più piastrelle")

                let size = strip.outputSize(mirrored: mirrored)
                let url = tmp.appendingPathComponent("tile-\(axis.rawValue)-\(width)-\(mirrored).png")
                try StripExporter.write(strip: strip, to: url, reversedOrder: false, mirrored: mirrored)

                let got = try readPNG(url)
                XCTAssertEqual(got.w, size.width, "larghezza dichiarata e scritta devono coincidere")
                XCTAssertEqual(got.h, size.height, "altezza dichiarata e scritta devono coincidere")

                // Nessuna fascia interamente nera lungo l'asse del tempo:
                // sarebbe tela mai disegnata, cioè byte promessi e riempiti
                // dallo scrittore invece che fotogrammi.
                var empty = 0
                let long = axis == .vertical ? got.w : got.h
                for i in 0..<long {
                    var sum = 0
                    if axis == .vertical {
                        for y in 0..<got.h { sum += Int(got.pixels[(y * got.w + i) * 4]) }
                    } else {
                        for x in 0..<got.w { sum += Int(got.pixels[(i * got.w + x) * 4]) }
                    }
                    if sum == 0 { empty += 1 }
                }
                XCTAssertEqual(empty, 0, "nessuna fascia di tela vuota (\(axis.rawValue)/\(width)/\(mirrored))")
            }
        }
    }

    func testTileFillIsRecordedNotDeduced() {
        let strip = StripBuffer(axis: .vertical, cross: 8)
        let slice = [UInt8](repeating: 255, count: 24 * 8 * 4)
        for _ in 0..<200 { strip.append(slice: slice, step: 24) }
        let total = strip.tiles.reduce(0) { $0 + $1.fill }
        XCTAssertEqual(total, strip.length,
                       "la somma dei riempimenti deve valere la lunghezza, non il numero di piastrelle per 4096")
        XCTAssertLessThan(strip.tiles[0].fill, StripBuffer.tileLength,
                          "con una fetta da 24 px la prima piastrella non arriva piena")
    }

    // MARK: - Impostazioni

    func testSettingsClamping() throws {
        var s = ScanSettings()
        s.kernel.width = 1_000_000
        s.kernel.feather = 8
        s.kernel.angle = 99
        s.scale = -4
        s.step = 0
        s.basePosition = 40
        s.drift = 999
        s.maxLength = 1
        s.stripCount = 99

        let c = s.clamped()
        XCTAssertTrue(ScanSettings.Limits.slitWidth.contains(c.kernel.width))
        XCTAssertTrue(ScanSettings.Limits.feather.contains(c.kernel.feather))
        XCTAssertTrue(ScanSettings.Limits.angle.contains(c.kernel.angle))
        XCTAssertTrue(ScanSettings.Limits.scale.contains(c.scale))
        XCTAssertTrue(ScanSettings.Limits.step.contains(c.step))
        XCTAssertTrue(ScanSettings.Limits.position.contains(c.basePosition))
        XCTAssertTrue(ScanSettings.Limits.drift.contains(c.drift))
        XCTAssertTrue(ScanSettings.Limits.maxLength.contains(c.maxLength))
        XCTAssertTrue(ScanSettings.Limits.stripCount.contains(c.stripCount))
    }

    /// Lo srotolamento vuole la fenditura ferma: una deriva lo trasformerebbe
    /// in una strisciata storta senza dirlo.
    func testRolloutForcesFixedSlit() {
        var s = ScanSettings()
        s.mode = .rollout
        s.trajectory = .linear(position: 0.5, drift: 3)
        if case .fixed = s.clamped().trajectory {} else {
            XCTFail("in srotolamento la traiettoria deve tornare ferma")
        }
    }

    func testSettingsRoundTripThroughJSON() throws {
        var s = ScanSettings()
        s.kernel = SlitKernel(width: 12, feather: 0.4, angle: 0.3)
        s.mode = .timeDisplacement
        s.axis = .horizontal
        s.mirrored = true
        s.trajectory = .keyframed(keys: [.init(slice: 0, position: 0.2),
                                         .init(slice: 40, position: 0.8)],
                                  easing: .smooth)
        let back = try ScanSettings.from(jsonData: try s.jsonData())
        XCTAssertEqual(back, s)
    }

    func testSettingsFromCorruptJSONIsRejected() {
        let junk = Data(#"{"width":"molti"}"#.utf8)
        XCTAssertThrowsError(try ScanSettings.from(jsonData: junk))
    }
}
