import AVFoundation

// Captures microphone audio while active and converts it to the format
// Deepgram wants: 16 kHz, mono, 16-bit PCM (linear16). Returns the raw
// PCM bytes when stopped.

final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var pcm = Data()
    private let lock = NSLock()

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    func start() {
        lock.lock(); pcm.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            logf("audio capture started (input \(Int(inputFormat.sampleRate))Hz -> 16000Hz)")
        } catch {
            logf("audio engine start failed: \(error.localizedDescription)")
        }
    }

    func stop() -> Data {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); let data = pcm; lock.unlock()
        logf("audio capture stopped (\(data.count) bytes PCM16)")
        return data
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        var provided = false
        _ = converter.convert(to: out, error: &error) { _, outStatus in
            if provided { outStatus.pointee = .noDataNow; return nil }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let error {
            logf("audio convert error: \(error.localizedDescription)")
            return
        }
        guard out.frameLength > 0, let channel = out.int16ChannelData else { return }
        let bytes = Data(bytes: channel[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
        lock.lock(); pcm.append(bytes); lock.unlock()
    }
}
