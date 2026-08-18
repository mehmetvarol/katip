import AVFoundation

/// Mikrofonu dinler ve Whisper'ın beklediği formata (16 kHz mono Float32) çevirir.
final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case noConverter
        case tooShort

        var errorDescription: String? {
            switch self {
            case .noConverter: "Ses formatı dönüştürülemedi."
            case .tooShort: "Kayıt çok kısa."
            }
        }
    }

    static let sampleRate = 16_000.0
    private static let minimumSamples = Int(sampleRate * 0.3)

    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
        channels: 1, interleaved: false)!

    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()

    private(set) var isRecording = false

    /// Ses seviyesi (0...1) — HUD/ikon için. Mikrofonun sessiz olduğunu erken fark etmek kritik.
    private(set) var level: Float = 0

    /// Kayıt boyunca görülen en yüksek genlik. 0'a yakınsa mikrofon sessizdir.
    private(set) var lastPeak: Float = 0

    /// VAD ayrı tipte: mikrofon olmadan test edilebilsin (bkz. SpeechSegmenter).
    private var segmenter = SpeechSegmenter()
    private var cutIndex: Int?

    func start() throws {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lastPeak = 0
        resetVAD()
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw RecorderError.noConverter
        }
        self.converter = converter

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    @discardableResult
    func stop(requireMinimum: Bool = true) throws -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        level = 0

        lock.lock()
        let out = samples
        lock.unlock()

        guard !requireMinimum || out.count >= Self.minimumSamples else {
            throw RecorderError.tooShort
        }
        return out
    }

    func cancel() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        level = 0
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, let channel = out.floatChannelData else { return }
        let frames = Int(out.frameLength)
        guard frames > 0 else { return }

        let chunk = UnsafeBufferPointer(start: channel[0], count: frames)

        var peak: Float = 0
        for sample in chunk { peak = max(peak, abs(sample)) }
        level = peak
        lastPeak = max(lastPeak, peak)

        lock.lock()
        samples.append(contentsOf: chunk)
        updateVAD(peak: peak, frames: frames)
        lock.unlock()
    }

    /// Kilit modunda hazır bir cümle parçası varsa döner ve tampondan çıkarır.
    /// Yoksa `nil` — kayıt kesintisiz devam eder.
    func takeSegment() -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard let cut = cutIndex, cut > 0, cut <= samples.count else { return nil }
        let segment = Array(samples[0..<cut])
        samples.removeFirst(cut)
        cutIndex = nil
        return segment
    }

    private func resetVAD() {
        segmenter.reset()
        cutIndex = nil
    }

    private func updateVAD(peak: Float, frames: Int) {
        guard cutIndex == nil else { return }   // bekleyen parça varken yeni kesme yok
        cutIndex = segmenter.feed(peak: peak, frames: frames, bufferedSamples: samples.count)
    }
}
