import XCTest
@testable import FenditturaCore

/// Prove del campionatore continuo.
///
/// La morbidezza di uno slit-scan non è un effetto applicato dopo: è il modo
/// in cui si legge la sorgente. Qui si verifica numericamente che i tre
/// meccanismi facciano ciò che dichiarano, su fotogrammi costruiti in modo che
/// il risultato giusto sia calcolabile a mano.
final class SamplerTests: XCTestCase {

    /// Fotogramma BGRA con un valore per colonna, uguale su tutte le righe.
    private func rampFrame(width: Int, height: Int, value: (Int) -> UInt8) -> [UInt8] {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = value(x)
                let o = (y * width + x) * 4
                px[o] = v; px[o + 1] = v; px[o + 2] = v; px[o + 3] = 255
            }
        }
        return px
    }

    private func source(_ px: UnsafePointer<UInt8>, _ w: Int, _ h: Int) -> PixelSource {
        PixelSource(base: px, width: w, height: h, stride: w * 4)
    }

    // MARK: - Sub-pixel

    /// Una rampa lineare letta a metà fra due pixel deve dare esattamente la
    /// media dei due. È il cuore del sub-pixel: senza, si otterrebbe il valore
    /// di uno dei due, e la deriva frazionaria procederebbe a scatti.
    func testBilinearHalfwayIsTheAverage() {
        let w = 32, h = 4
        let px = rampFrame(width: w, height: h) { UInt8($0 * 8) }
        px.withUnsafeBufferPointer { buf in
            let s = source(buf.baseAddress!, w, h)
            let left = SlitSampler.bilinear(s, 10.5, 2.0)      // centro del pixel 10
            let right = SlitSampler.bilinear(s, 11.5, 2.0)     // centro del pixel 11
            let middle = SlitSampler.bilinear(s, 11.0, 2.0)    // esattamente in mezzo

            XCTAssertEqual(left.0, 80, accuracy: 0.01, "pixel 10 vale 80")
            XCTAssertEqual(right.0, 88, accuracy: 0.01, "pixel 11 vale 88")
            XCTAssertEqual(middle.0, 84, accuracy: 0.01, "a metà strada deve dare 84, non 80 né 88")
        }
    }

    func testBilinearClampsAtEdges() {
        let w = 8, h = 4
        let px = rampFrame(width: w, height: h) { UInt8($0 * 10) }
        px.withUnsafeBufferPointer { buf in
            let s = source(buf.baseAddress!, w, h)
            XCTAssertEqual(SlitSampler.bilinear(s, -50, 2).0, 0, accuracy: 0.01)
            XCTAssertEqual(SlitSampler.bilinear(s, 999, 2).0, 70, accuracy: 0.01)
        }
    }

    // MARK: - Interpolazione temporale

    /// Due fotogrammi uniformi, uno scuro e uno chiaro: a metà strada il
    /// risultato deve stare in mezzo. Senza fusione temporale si otterrebbe
    /// uno dei due ripetuto, ed è la causa principale delle bande dure.
    func testTemporalBlendSitsBetweenFrames() {
        let w = 16, h = 8
        let a = rampFrame(width: w, height: h) { _ in 40 }
        let b = rampFrame(width: w, height: h) { _ in 200 }

        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                let sa = source(pa.baseAddress!, w, h)
                let sb = source(pb.baseAddress!, w, h)
                var out = [UInt8](repeating: 0, count: 1 * h * 4)

                for (mix, want) in [(0.0, 40.0), (0.5, 120.0), (1.0, 200.0)] {
                    SlitSampler.slice(a: sa, b: sb, mix: mix, axis: .vertical,
                                      centre: 8, kernel: SlitKernel(width: 1),
                                      outCross: h, outStep: 1, into: &out)
                    XCTAssertEqual(Double(out[0]), want, accuracy: 1.5,
                                   "fusione a \(mix): atteso \(want)")
                }
            }
        }
    }

    // MARK: - Finestra temporale

    /// Tre fotogrammi uniformi mediati con pesi uguali devono dare la media
    /// aritmetica. È il meccanismo che rende continue le transizioni: due
    /// fotogrammi tolgono le bande dure ma lasciano un doppio contorno, molti
    /// producono una lunga esposizione sull'asse del tempo.
    func testTemporalWindowAveragesAllFrames() {
        let w = 16, h = 8
        let a = rampFrame(width: w, height: h) { _ in 30 }
        let b = rampFrame(width: w, height: h) { _ in 120 }
        let c = rampFrame(width: w, height: h) { _ in 210 }

        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                c.withUnsafeBufferPointer { pc in
                    let frames = [source(pa.baseAddress!, w, h),
                                  source(pb.baseAddress!, w, h),
                                  source(pc.baseAddress!, w, h)]
                    var out = [UInt8](repeating: 0, count: h * 4)
                    SlitSampler.slice(frames: frames, weights: [1, 1, 1],
                                      axis: .vertical, centre: 8,
                                      kernel: SlitKernel(width: 1),
                                      outCross: h, outStep: 1, into: &out)
                    XCTAssertEqual(Double(out[0]), 120, accuracy: 1.5,
                                   "media di 30, 120 e 210")
                }
            }
        }
    }

    /// Con i pesi a campana il fotogramma centrale domina, quindi il risultato
    /// tende al suo valore invece che alla media piatta.
    func testTemporalFeatherFavoursTheMiddleFrame() {
        let w = 16, h = 8
        let a = rampFrame(width: w, height: h) { _ in 0 }
        let b = rampFrame(width: w, height: h) { _ in 255 }
        let c = rampFrame(width: w, height: h) { _ in 0 }

        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                c.withUnsafeBufferPointer { pc in
                    let frames = [source(pa.baseAddress!, w, h),
                                  source(pb.baseAddress!, w, h),
                                  source(pc.baseAddress!, w, h)]
                    var flat = [UInt8](repeating: 0, count: h * 4)
                    var bell = [UInt8](repeating: 0, count: h * 4)
                    let kernel = SlitKernel(width: 1)
                    SlitSampler.slice(frames: frames,
                                      weights: SlitSampler.temporalWeights(count: 3, feather: 0),
                                      axis: .vertical, centre: 8, kernel: kernel,
                                      outCross: h, outStep: 1, into: &flat)
                    SlitSampler.slice(frames: frames,
                                      weights: SlitSampler.temporalWeights(count: 3, feather: 1),
                                      axis: .vertical, centre: 8, kernel: kernel,
                                      outCross: h, outStep: 1, into: &bell)
                    XCTAssertEqual(Double(flat[0]), 85, accuracy: 2, "media piatta di 0, 255, 0")
                    XCTAssertGreaterThan(Int(bell[0]), Int(flat[0]),
                                         "la campana pesa il fotogramma centrale, che qui è bianco")
                }
            }
        }
    }

    func testTemporalWeightsShape() {
        XCTAssertEqual(SlitSampler.temporalWeights(count: 1, feather: 1), [1])
        let flat = SlitSampler.temporalWeights(count: 5, feather: 0)
        XCTAssertEqual(Set(flat).count, 1, "senza morbidezza i fotogrammi pesano uguale")
        let bell = SlitSampler.temporalWeights(count: 5, feather: 1)
        XCTAssertGreaterThan(bell[2], bell[0])
        XCTAssertEqual(bell[0], bell[4], accuracy: 1e-9, "la campana è simmetrica")
    }

    // MARK: - Sfumatura

    /// Su un gradino, la fenditura sfumata pesa il centro più dei bordi,
    /// quindi il risultato tende al valore che sta sotto il centro. Quella
    /// netta media tutta la finestra allo stesso modo.
    ///
    /// La fenditura va messa **fuori centro** rispetto al gradino: su un
    /// gradino perfettamente centrato qualunque profilo simmetrico dà lo
    /// stesso numero, e la prova non direbbe niente.
    func testFeatherPullsTowardTheCentreOfTheSlit() {
        let w = 96, h = 8
        let px = rampFrame(width: w, height: h) { $0 < 32 ? 0 : 255 }
        px.withUnsafeBufferPointer { buf in
            let s = source(buf.baseAddress!, w, h)
            var hard = [UInt8](repeating: 0, count: h * 4)
            var soft = [UInt8](repeating: 0, count: h * 4)

            // finestra da 16 px centrata a 36: copre 28…44, cioè 4 px di nero
            // e 12 di bianco. Il centro cade nel bianco.
            let kernel = { (f: Double) in SlitKernel(width: 16, feather: f) }
            SlitSampler.slice(a: s, axis: .vertical, centre: 36,
                              kernel: kernel(0), outCross: h, outStep: 1, into: &hard)
            SlitSampler.slice(a: s, axis: .vertical, centre: 36,
                              kernel: kernel(1), outCross: h, outStep: 1, into: &soft)

            XCTAssertGreaterThan(Int(hard[0]), 120, "la finestra netta è per tre quarti bianca")
            XCTAssertLessThan(Int(hard[0]), 250, "ma contiene anche del nero")
            XCTAssertGreaterThan(Int(soft[0]), Int(hard[0]),
                                 "la campana pesa il centro, che qui è bianco, quindi schiarisce")
        }
    }

    /// L'altra faccia della stessa proprietà: su un gradino centrato, i due
    /// profili devono dare lo stesso risultato, perché entrambi sono
    /// simmetrici. Se un giorno smettessero di esserlo, questa prova lo
    /// direbbe prima che se ne accorga l'occhio.
    func testSymmetricKernelsAgreeOnACentredEdge() {
        let w = 96, h = 8
        let px = rampFrame(width: w, height: h) { $0 < 48 ? 0 : 255 }
        px.withUnsafeBufferPointer { buf in
            let s = source(buf.baseAddress!, w, h)
            var hard = [UInt8](repeating: 0, count: h * 4)
            var soft = [UInt8](repeating: 0, count: h * 4)
            SlitSampler.slice(a: s, axis: .vertical, centre: 48,
                              kernel: SlitKernel(width: 16, feather: 0),
                              outCross: h, outStep: 1, into: &hard)
            SlitSampler.slice(a: s, axis: .vertical, centre: 48,
                              kernel: SlitKernel(width: 16, feather: 1),
                              outCross: h, outStep: 1, into: &soft)
            XCTAssertEqual(Int(hard[0]), Int(soft[0]), accuracy: 1,
                           "su un gradino centrato i profili simmetrici coincidono")
        }
    }

    /// I pesi devono essere piatti a sfumatura zero e a campana a uno.
    func testKernelWeightProfile() {
        let flat = SlitSampler.kernelWeights(SlitKernel(width: 9, feather: 0))
        XCTAssertEqual(Set(flat).count, 1, "a sfumatura zero i pesi sono tutti uguali")

        let bell = SlitSampler.kernelWeights(SlitKernel(width: 9, feather: 1))
        let mid = bell.count / 2
        XCTAssertGreaterThan(bell[mid], bell[0], "il centro deve pesare più del bordo")
        XCTAssertGreaterThan(bell[mid], bell[bell.count - 1])
        XCTAssertEqual(bell[0], bell[bell.count - 1], accuracy: 1e-9, "la campana è simmetrica")
    }

    /// Una fenditura inclinata deve leggere posizioni diverse a seconda di
    /// dove ci si trova lungo il taglio.
    func testAngledSlitReadsDifferentColumns() {
        let w = 64, h = 32
        let px = rampFrame(width: w, height: h) { UInt8(min(255, $0 * 4)) }
        px.withUnsafeBufferPointer { buf in
            let s = source(buf.baseAddress!, w, h)
            var out = [UInt8](repeating: 0, count: h * 4)
            SlitSampler.slice(a: s, axis: .vertical, centre: 32,
                              kernel: SlitKernel(width: 1, feather: 0, angle: 0.6),
                              outCross: h, outStep: 1, into: &out)
            let top = Int(out[0])
            let bottom = Int(out[(h - 1) * 4])
            XCTAssertNotEqual(top, bottom, "con la fenditura inclinata i due capi leggono colonne diverse")
        }
    }

    // MARK: - Traiettoria

    func testLinearTrajectoryMatchesDrift() {
        let t = Trajectory.linear(position: 0.5, drift: 2)
        XCTAssertEqual(t.position(atSlice: 0, crossSize: 100), 50, accuracy: 1e-9)
        XCTAssertEqual(t.position(atSlice: 10, crossSize: 100), 70, accuracy: 1e-9)
    }

    func testKeyframedTrajectoryInterpolates() {
        let keys = [Trajectory.Keyframe(slice: 0, position: 0.0),
                    Trajectory.Keyframe(slice: 100, position: 1.0)]
        let linear = Trajectory.keyframed(keys: keys, easing: .linear)
        XCTAssertEqual(linear.position(atSlice: 50, crossSize: 200), 100, accuracy: 1e-9,
                       "a metà fra due chiavi, con raccordo dritto, sta a metà")
        XCTAssertEqual(linear.position(atSlice: -5, crossSize: 200), 0, accuracy: 1e-9,
                       "prima della prima chiave resta ferma")
        XCTAssertEqual(linear.position(atSlice: 999, crossSize: 200), 200, accuracy: 1e-9,
                       "dopo l'ultima chiave resta ferma")

        // Il raccordo morbido parte e arriva più lento, quindi al quarto del
        // percorso è indietro rispetto al dritto.
        let smooth = Trajectory.keyframed(keys: keys, easing: .smooth)
        XCTAssertLessThan(smooth.position(atSlice: 25, crossSize: 200),
                          linear.position(atSlice: 25, crossSize: 200))
        XCTAssertEqual(smooth.position(atSlice: 50, crossSize: 200), 100, accuracy: 1e-9,
                       "a metà i due raccordi coincidono")
    }

    func testTrajectorySurvivesJSON() throws {
        let original = Trajectory.keyframed(
            keys: [.init(slice: 0, position: 0.2), .init(slice: 60, position: 0.9)],
            easing: .smooth)
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(Trajectory.self, from: data)
        XCTAssertEqual(back, original)
    }

    func testScanModeOutputBounds() {
        XCTAssertTrue(ScanMode.strip.hasUnboundedOutput)
        XCTAssertFalse(ScanMode.timeDisplacement.hasUnboundedOutput,
                       "il time displacement ha le dimensioni di un fotogramma")
    }
}
