import Foundation

public enum VoiceWaveform {
    /// Read bounded PCM16 mono samples from WAV; skip optional RIFF metadata.
    public static func levels(_ data: Data, bins: Int = 32) -> [Double] {
        guard (1...128).contains(bins), data.count >= 44, data.count <= 2_000_000 else { return [] }
        let bytes = [UInt8](data)
        func word(_ i: Int) -> Int { Int(bytes[i]) | (Int(bytes[i + 1]) << 8) }
        func dword(_ i: Int) -> Int { word(i) | (word(i + 2) << 16) }
        guard String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else { return [] }
        var offset = 12, samples: Range<Int>?, validFormat = false
        while offset + 8 <= bytes.count {
            let id = String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii)
            let count = dword(offset + 4); offset += 8
            guard count >= 0, count <= bytes.count - offset else { return [] }
            if id == "fmt ", count >= 16 { validFormat = word(offset) == 1 && word(offset + 2) == 1 && word(offset + 14) == 16 }
            if id == "data" { samples = offset..<(offset + count) }
            offset += count + count % 2
        }
        guard validFormat, let samples, samples.count >= 2 else { return [] }
        let count = samples.count / 2
        return (0..<bins).map { bin in
            let start = bin * count / bins, end = max(start + 1, (bin + 1) * count / bins)
            var energy = 0.0
            for sample in start..<min(count, end) {
                let raw = word(samples.lowerBound + sample * 2)
                let signed = raw >= 32768 ? raw - 65536 : raw
                let amplitude = Double(signed) / 32768
                energy += amplitude * amplitude
            }
            return min(1, sqrt(energy / Double(max(1, end - start))) * 3)
        }
    }
}
