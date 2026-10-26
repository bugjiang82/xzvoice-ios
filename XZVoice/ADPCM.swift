import Foundation

/// IMA ADPCM decoder (matches firmware/adpcm.py: packed nibbles, low nibble first)
enum ADPCM {
    static let stepTab: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
        253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
        1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
        3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
        11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794,
        32767,
    ]
    static let idxTab = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]

    struct Decoder {
        var prev: Int = 0
        var idx: Int = 0

        mutating func reset() {
            prev = 0
            idx = 0
        }

        /// Decode packed ADPCM nibble stream into 16-bit little-endian mono PCM.
        mutating func decode(_ data: Data) -> Data {
            let n = data.count * 2
            var out = [UInt8](repeating: 0, count: n * 2)
            var oi = 0
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for i in 0..<n {
                    let b = Int(raw[i >> 1])
                    let nib = (i & 1) == 0 ? (b & 0x0F) : ((b >> 4) & 0x0F)
                    let step = stepTab[idx]
                    var d = step >> 3
                    if nib & 4 != 0 { d += step }
                    if nib & 2 != 0 { d += step >> 1 }
                    if nib & 1 != 0 { d += step >> 2 }
                    if nib & 8 != 0 { d = -d }
                    prev += d
                    prev = max(-32768, min(32767, prev))
                    idx = max(0, min(88, idx + idxTab[nib]))
                    let v = UInt16(truncatingIfNeeded: prev)
                    out[oi] = UInt8(v & 0xFF)
                    out[oi + 1] = UInt8(v >> 8)
                    oi += 2
                }
            }
            return Data(out)
        }
    }

    /// Build a WAV (PCM16 mono) container around raw PCM bytes.
    static func wavFile(pcm: Data, sampleRate: Int = 16000, channels: Int = 1) -> Data {
        var d = Data()
        let byteRate = sampleRate * channels * 2
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + pcm.count))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1) // PCM
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(UInt32(byteRate))
        append16(UInt16(channels * 2))
        append16(16)
        d.append(contentsOf: Array("data".utf8))
        append32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}
