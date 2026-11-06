import AVFoundation

/// Downmixes any float PCM buffer to mono and resamples it to the recording rate.
final class MonoResampler {
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(sampleRate: Double) {
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    func process(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let mono = Self.downmix(buffer) else { return [] }
        if mono.format.sampleRate == outputFormat.sampleRate {
            return Array(UnsafeBufferPointer(start: mono.floatChannelData![0], count: Int(mono.frameLength)))
        }
        if sourceFormat != mono.format {
            converter = AVAudioConverter(from: mono.format, to: outputFormat)
            sourceFormat = mono.format
        }
        guard let converter else { return [] }
        let ratio = outputFormat.sampleRate / mono.format.sampleRate
        let capacity = AVAudioFrameCount(Double(mono.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil else { return [] }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    static func downmix(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        guard format.commonFormat == .pcmFormatFloat32, let data = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        guard
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
            let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(max(frames, 1)))
        else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)
        let out = mono.floatChannelData![0]
        let scale = 1 / Float(max(channels, 1))
        for i in 0..<frames {
            var sum: Float = 0
            for ch in 0..<channels {
                sum += format.isInterleaved ? data[0][i * channels + ch] : data[ch][i]
            }
            out[i] = sum * scale
        }
        return mono
    }
}
