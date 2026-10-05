import AVFoundation
import Combine
import Foundation

@MainActor
final class VoiceNoteController: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    @Published private(set) var levels = Array(repeating: 0.05, count: 32)
    private var playbackData: Data?
    @Published private(set) var recording = false
    @Published private(set) var playing = false
    @Published private(set) var requestingPermission = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var recordedData: Data?
    @Published var error: String?
    var didRecord: ((Data) -> Void)?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var clockTask: Task<Void, Never>?
    private var generation = 0

    func record() async {
        guard !recording, !requestingPermission else { return }
        stopAll(); let request = generation
        requestingPermission = true; error = nil
        let granted = await AVAudioApplication.requestRecordPermission()
        guard request == generation else { return }
        requestingPermission = false
        guard granted else { error = "Permití el micrófono en Ajustes para grabar una nota de voz."; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            let value = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            value.delegate = self
            value.isMeteringEnabled = true
            levels = Array(repeating: 0.05, count: 32)
            recorder = value
            guard value.record(forDuration: 60) else { throw CocoaError(.fileWriteUnknown) }
            elapsed = 0; recording = true
            startClock()
        } catch { self.error = "No se pudo iniciar la grabación."; stopAll() }
    }
    func finishRecording() {
        guard let recorder else { return }
        recorder.delegate = nil; recorder.stop()
        let url = recorder.url
        self.recorder = nil; recording = false; clockTask?.cancel(); clockTask = nil
        defer { try? FileManager.default.removeItem(at: url); deactivate() }
        do {
            let data = try Data(contentsOf: url)
            guard data.count > 44, data.count <= 2_000_000 else { throw CocoaError(.fileReadCorruptFile) }
            duration = (try? AVAudioPlayer(data: data).duration) ?? elapsed
            elapsed = 0
            recordedData = data; didRecord?(data)
        } catch { self.error = "No se pudo conservar la grabación. Volvé a intentar." }
    }
    func prepare(_ data: Data) {
        guard playbackData != data else { return }
        stopAll(); error = nil
        do {
            let value = try AVAudioPlayer(data: data)
            value.delegate = self; player = value; playbackData = data
            duration = value.duration; elapsed = 0
            value.prepareToPlay()
        } catch { self.error = "No se pudo leer el audio." }
    }
    func play(_ data: Data) {
        prepare(data)
        guard let player else { return }
        error = nil
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
            guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
            playing = true; startClock()
        } catch { self.error = "No se pudo reproducir el audio."; pause() }
    }
    func pause() {
        player?.pause(); playing = false
        clockTask?.cancel(); clockTask = nil; deactivate()
    }
    func seek(to fraction: Double) {
        guard fraction.isFinite, let player else { return }
        player.currentTime = min(1, max(0, fraction)) * player.duration
        elapsed = player.currentTime
    }
    func suspend() {
        if recording || requestingPermission { stopAll() }
        else { pause() }
    }
    func stopAll() {
        generation += 1; requestingPermission = false
        if recorder != nil { finishRecording() }
        player?.stop(); player?.delegate = nil; player = nil; playbackData = nil; playing = false
        elapsed = 0; duration = 0
        clockTask?.cancel(); clockTask = nil; deactivate()
    }
    private func deactivate() { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let recorder = self.recorder {
                    recorder.updateMeters()
                    let level = min(1, max(0.05, pow(10, Double(recorder.averagePower(forChannel: 0)) / 40)))
                    self.levels = Array(self.levels.dropFirst()) + [level]
                }
                self.elapsed = self.recorder?.currentTime ?? self.player?.currentTime ?? 0
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.finishRecording()
            if !flag { self.error = "La grabación se interrumpió. Revisá el audio antes de enviar." }
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.pause(); self.elapsed = self.duration
            if !flag { self.error = "La reproducción se interrumpió. Podés volver a escucharla." }
        }
    }
}
