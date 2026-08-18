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
    /// Girdi hızında MONO ara format — kanal indirgemesini kendimiz yapıyoruz.
    private var monoInput: AVAudioFormat?
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

        // AVAudioConverter'a kanal indirgemesi YAPTIRMIYORUZ. MacBook'un dahili
        // mikrofonu 3 kanallı bir dizi olarak görünebiliyor ve dönüştürücü bu
        // düzeni mono'ya indiremiyor: hata vermiyor, sessizce SIFIR üretiyor.
        // (Ölçüldü: üç kanalda da ses var, dönüştürücü çıktısı tam sessiz —
        // "Ses algılanmadı" hatası tam olarak buydu.) Dönüştürücüye yalnızca
        // örnekleme hızı işi kalıyor; onu güvenilir şekilde yapıyor.
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: inputFormat.sampleRate,
                                       channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: target) else {
            throw RecorderError.noConverter
        }
        self.monoInput = mono
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

    /// Çok kanallı girdiden TEK kanal alır. Kanalları ortalamak dizideki
    /// mikrofonlar arasındaki faz farkı yüzünden sinyali kısmen iptal edebilir;
    /// tek mikrofon sinyali her koşulda güvenli.
    private func downmix(_ buffer: AVAudioPCMBuffer, to mono: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0,
              let source = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let destination = out.floatChannelData else { return nil }
        out.frameLength = buffer.frameLength

        if buffer.format.isInterleaved {
            let stride = Int(buffer.format.channelCount)
            for index in 0..<frames { destination[0][index] = source[0][index * stride] }
        } else {
            destination[0].update(from: source[0], count: frames)
        }
        return out
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let mono = monoInput,
              let source = downmix(buffer, to: mono) else { return }

        let ratio = target.sampleRate / mono.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024
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
            return source
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

    /// Sentetik çok kanallı bir tamponu GERÇEK dönüşüm hattından geçirir.
    /// Mikrofon ve akustik devre dışı — kanal indirgemesinin çalışıp çalışmadığını
    /// kesin olarak söyler. Hoparlörden ses çalıp mikrofonla dinlemek bu soruyu
    /// cevaplayamıyor: macOS kendi çaldığı sesi girdiden iptal ediyor.
    /// `source` GERÇEK donanım formatı olmalı. Sentetik çok kanallı format
    /// üretemiyoruz: `AVAudioFormat(commonFormat:channels:)` 2'den fazla kanalı
    /// desteklemiyor (kanal düzeni istiyor) — donanımdan geleni kullanmak hem
    /// mümkün hem de sınanmak istenen şeyin ta kendisi.
    static func conversionSelfCheck(source: AVAudioFormat) -> (input: Float, output: Float)? {
        let frames: AVAudioFrameCount = 4800
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames

        // 440 Hz sinüs, genlik 0.5 — her kanala aynısı.
        let amplitude: Float = 0.5
        for channel in 0..<Int(source.channelCount) {
            for frame in 0..<Int(frames) {
                data[channel][frame] =
                    amplitude * sinf(2 * .pi * 440 * Float(frame) / Float(source.sampleRate))
            }
        }

        let recorder = AudioRecorder()
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: source.sampleRate,
                                       channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: recorder.target) else { return nil }
        recorder.monoInput = mono
        recorder.converter = converter
        recorder.append(buffer)
        return (amplitude, recorder.lastPeak)
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
