import Foundation
import Compression

/// Scrittore PNG incrementale.
///
/// Una striscia slit-scan supera con facilità qualunque limite di immagine in
/// memoria: 100.000 × 1080 pixel sono 432 MB di soli dati grezzi. Qui le righe
/// arrivano a blocchi e finiscono compresse su disco man mano, quindi
/// l'immagine intera non esiste mai per intero e il limite diventa lo spazio
/// libero.
///
/// Il flusso di Apple (`Compression`) produce DEFLATE crudo, mentre un blocco
/// IDAT vuole DEFLATE avvolto in zlib: due byte di intestazione davanti e
/// l'impronta Adler-32 in coda. Quei tre pezzi li aggiunge questa classe.
public final class PNGStreamWriter {

    public enum Failure: Error, CustomStringConvertible {
        case invalidSize
        case cannotCreateFile(String)
        case shortBlock(expected: Int, got: Int)
        case alreadyClosed
        case compressionFailed
        case writeFailed(String)

        public var description: String {
            switch self {
            case .invalidSize: return "dimensioni non valide"
            case .cannotCreateFile(let p): return "non riesco a creare \(p)"
            case .shortBlock(let e, let g): return "blocco di righe più corto del previsto: attesi \(e) byte, ricevuti \(g)"
            case .alreadyClosed: return "scrittore già chiuso"
            case .compressionFailed: return "compressione fallita"
            case .writeFailed(let m): return "scrittura fallita: \(m)"
            }
        }
    }

    public let width: Int
    public let height: Int
    public private(set) var rowsWritten = 0

    private let url: URL
    private let handle: FileHandle
    private let bytesPerRow: Int
    private var closed = false
    private var discarded = false

    private var stream: UnsafeMutablePointer<compression_stream>
    private var streamInitialised = false
    private var adler: (a: UInt32, b: UInt32) = (1, 0)
    private var outBuffer: UnsafeMutablePointer<UInt8>
    private let outCapacity = 1 << 18
    // Sorgente fittizia per la chiusura del flusso: `src_size` vale zero, ma
    // `src_ptr` deve puntare a memoria valida e non a un indirizzo inventato.
    private let emptySource = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)

    // MARK: - Avvio

    public init(url: URL, width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw Failure.invalidSize }
        self.url = url
        self.width = width
        self.height = height
        self.bytesPerRow = width * 4

        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw Failure.cannotCreateFile(url.path)
        }
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw Failure.cannotCreateFile(url.path)
        }

        outBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: outCapacity)
        stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        let status = compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
        guard status == COMPRESSION_STATUS_OK else {
            outBuffer.deallocate()
            stream.deallocate()
            throw Failure.compressionFailed
        }
        streamInitialised = true
        stream.pointee.dst_ptr = outBuffer
        stream.pointee.dst_size = outCapacity

        try writeSignatureAndHeader()
    }

    deinit {
        if streamInitialised { compression_stream_destroy(stream) }
        stream.deallocate()
        outBuffer.deallocate()
        emptySource.deallocate()
    }

    // MARK: - Righe

    /// `raw` contiene `rowCount` righe RGBA contigue, ognuna di `width * 4` byte.
    public func write(rows raw: UnsafeRawBufferPointer, rowCount: Int) throws {
        guard !closed else { throw Failure.alreadyClosed }
        let needed = rowCount * bytesPerRow
        guard raw.count >= needed else { throw Failure.shortBlock(expected: needed, got: raw.count) }

        // Filtro 1 (Sub): differenza con il pixel a sinistra. Su una striscia
        // fotografica toglie circa un terzo al file e costa una sottrazione
        // per byte.
        var line = [UInt8](repeating: 0, count: bytesPerRow + 1)
        let base = raw.bindMemory(to: UInt8.self).baseAddress!

        for r in 0..<rowCount {
            if rowsWritten >= height { break }
            let src = base + r * bytesPerRow
            line[0] = 1
            line[1] = src[0]; line[2] = src[1]; line[3] = src[2]; line[4] = src[3]
            if bytesPerRow > 4 {
                for i in 4..<bytesPerRow {
                    line[i + 1] = src[i] &- src[i - 4]
                }
            }
            try feed(line)
            rowsWritten += 1
        }
    }

    /// Comodità per chi ha già un array.
    public func write(rows raw: [UInt8], rowCount: Int) throws {
        try raw.withUnsafeBytes { try write(rows: $0, rowCount: rowCount) }
    }

    // MARK: - Chiusura

    public func finish() throws {
        guard !closed else { return }
        closed = true

        // Meno righe di quelle dichiarate: il resto va riempito, perché un PNG
        // troncato non lo apre nessun programma e sembra soltanto un file rotto.
        if rowsWritten < height {
            let filler = [UInt8](repeating: 0, count: bytesPerRow + 1)
            while rowsWritten < height {
                try feed(filler)
                rowsWritten += 1
            }
        }

        try flush(final: true)
        try appendChunk(type: "IEND", payload: Data())
        try handle.close()
    }

    /// Annullamento: il file parziale non deve restare sul disco dell'utente.
    public func abort() {
        guard !closed else { return }
        closed = true
        try? handle.close()
        discard()
    }

    private func discard() {
        guard !discarded else { return }
        discarded = true
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Interno

    private func writeSignatureAndHeader() throws {
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try append(signature)

        var ihdr = Data()
        ihdr.append(bigEndian: UInt32(width))
        ihdr.append(bigEndian: UInt32(height))
        ihdr.append(8)     // 8 bit per canale
        ihdr.append(6)     // RGBA
        ihdr.append(0)     // compressione deflate
        ihdr.append(0)     // filtro adattivo
        ihdr.append(0)     // non interlacciato
        try appendChunk(type: "IHDR", payload: ihdr)

        // Intestazione zlib: 0x78 0x01 è deflate a finestra 32 KB.
        pendingZlibHeader = Data([0x78, 0x01])
    }

    private var pendingZlibHeader: Data?
    private var idatBuffer = Data()

    private func feed(_ line: [UInt8]) throws {
        updateAdler(line)
        try line.withUnsafeBufferPointer { buf in
            stream.pointee.src_ptr = buf.baseAddress!
            stream.pointee.src_size = buf.count
            while stream.pointee.src_size > 0 {
                let status = compression_stream_process(stream, 0)
                guard status != COMPRESSION_STATUS_ERROR else { throw Failure.compressionFailed }
                if stream.pointee.dst_size == 0 {
                    try drainCompressed()
                }
                if status == COMPRESSION_STATUS_END { break }
            }
        }
        if idatBuffer.count >= (1 << 18) { try emitIDAT() }
    }

    private func flush(final: Bool) throws {
        stream.pointee.src_ptr = UnsafePointer(emptySource)
        stream.pointee.src_size = 0
        var status = COMPRESSION_STATUS_OK
        repeat {
            status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            guard status != COMPRESSION_STATUS_ERROR else { throw Failure.compressionFailed }
            try drainCompressed()
        } while status != COMPRESSION_STATUS_END

        if final {
            // Coda zlib: Adler-32 del flusso non compresso, in big endian.
            var tail = Data()
            let sum = (adler.b << 16) | adler.a
            tail.append(bigEndian: sum)
            idatBuffer.append(tail)
        }
        try emitIDAT()
    }

    private func drainCompressed() throws {
        let produced = outCapacity - stream.pointee.dst_size
        if produced > 0 {
            idatBuffer.append(contentsOf: UnsafeBufferPointer(start: outBuffer, count: produced))
            stream.pointee.dst_ptr = outBuffer
            stream.pointee.dst_size = outCapacity
        }
    }

    private func emitIDAT() throws {
        try drainCompressed()
        guard !idatBuffer.isEmpty || pendingZlibHeader != nil else { return }
        var payload = Data()
        if let header = pendingZlibHeader {
            payload.append(header)
            pendingZlibHeader = nil
        }
        payload.append(idatBuffer)
        idatBuffer.removeAll(keepingCapacity: true)
        guard !payload.isEmpty else { return }
        try appendChunk(type: "IDAT", payload: payload)
    }

    private func updateAdler(_ bytes: [UInt8]) {
        var a = adler.a
        var b = adler.b
        for byte in bytes {
            a = (a &+ UInt32(byte)) % 65521
            b = (b &+ a) % 65521
        }
        adler = (a, b)
    }

    private func appendChunk(type: String, payload: Data) throws {
        var body = Data(type.utf8)
        body.append(payload)
        var out = Data()
        out.append(bigEndian: UInt32(payload.count))
        out.append(body)
        out.append(bigEndian: CRC32.checksum(body))
        try append(out)
    }

    private func append(_ data: Data) throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }
}

// MARK: - CRC32

public enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { n -> UInt32 in
            var c = UInt32(n)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1
            }
            return c
        }
    }()

    public static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data {
            c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFFFFFF
    }
}

extension Data {
    mutating func append(bigEndian value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
