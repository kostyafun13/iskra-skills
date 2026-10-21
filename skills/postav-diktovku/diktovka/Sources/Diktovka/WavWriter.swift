import Foundation

/// float-сэмплы → WAV (PCM 16 бит, моно)
enum WavWriter {
    static func write(samples: [Float], sampleRate: Int, to url: URL) throws {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)

        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        u32(16)
        u16(1)                        // PCM
        u16(1)                        // моно
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))   // байт/сек
        u16(2)                        // блок
        u16(16)                       // бит
        data.append(contentsOf: Array("data".utf8))
        u32(UInt32(dataSize))

        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() {
            pcm[i] = Int16(max(-1, min(1, s)) * 32767)
        }
        pcm.withUnsafeBytes { raw in data.append(contentsOf: raw) }

        try data.write(to: url)
    }
}
