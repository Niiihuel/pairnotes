import AVFoundation
import Combine
import Foundation
import QuartzCore
import UIKit

/// Keep the recorded history at ten samples per second on both 60 and 120 Hz displays.
struct VoiceMeterCadence {
    static let interval: TimeInterval = 0.1
    private var lastSample: TimeInterval?
    mutating func shouldSample(at timestamp: TimeInterval) -> Bool {
        guard timestamp.isFinite, timestamp >= 0 else { return false }
        if let lastSample, timestamp >= lastSample, timestamp - lastSample + 0.000_001 < Self.interval { return false }
        lastSample = timestamp
        return true
    }
}

@MainActor
private final class VoiceDisplayLinkTarget: NSObject {
    weak var controller: VoiceNoteController?
    init(_ controller: VoiceNoteController) { self.controller = controller }
    @objc func update(_ link: CADisplayLink) {
        guard let controller else { link.invalidate(); return }
        controller.updateDisplay(link)
    }
}

/// Owns cleanup without accessing an actor-isolated controller from its deinitializer.
private final class VoiceDisplayLinkLifetime {
    var link: CADisplayLink?
    deinit { link?.invalidate() }
}

@MainActor
final class VoiceNoteController: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    @Published private(set) var levels = Array(repeating: 0.05, count: 32)
    private var playbackData: Data?
    @Published private(set) var recording = false
    @Published private(set) var playing = false
    @Published private(set) var requestingPermission = false
    @Published private(set) var needsMicrophoneSettings = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var recordedData: Data?
    @Published var error: String?
    var didRecord: ((Data) -> Void)?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private let display = VoiceDisplayLinkLifetime()
    private var meterCadence = VoiceMeterCadence()
    var isUpdatingDisplay: Bool { display.link != nil }
    private var generation = 0
    private var observers = Set<AnyCancellable>()
    private static weak var sessionOwner: VoiceNoteController?

    override init() {
        super.init()
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                let raw = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                Task { @MainActor [weak self] in
                    guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                    self?.handleInterruption()
                }
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] notification in
                let raw = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                Task { @MainActor [weak self] in
                    guard raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                    self?.handleInterruption()
                }
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let active = self.recording || self.playing
                    self.stopAll()
                    if active { self.error = "El audio se interrumpió. Volvé a intentarlo." }
                }
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleInterruption() }
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.suspend() }
            }.store(in: &observers)
    }

    func record() async {
        guard !recording, !requestingPermission else { return }
        // Keep the previous reviewed take ready if permission or the new recording fails.
        pause(); generation += 1
        let request = generation
        requestingPermission = true; needsMicrophoneSettings = false; error = nil
        let granted = await AVAudioApplication.requestRecordPermission()
        guard request == generation else { return }
        requestingPermission = false
        guard !Task.isCancelled else { return }
        guard granted else { needsMicrophoneSettings = true; error = "Permití el acceso al micrófono para grabar."; return }
        do {
            try activate(category: .record, mode: .default, options: [.allowBluetoothHFP])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            let value = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            value.delegate = self
            value.isMeteringEnabled = true
            levels = Array(repeating: 0.05, count: 32)
            recorder = value
            guard value.record(forDuration: 60) else { throw CocoaError(.fileWriteUnknown) }
            elapsed = 0; duration = 0; recording = true
            startClock()
        } catch { cancelRecording(); self.error = "No se pudo iniciar la grabación." }
    }
    func finishRecording() {
        guard let recorder else { return }
        recorder.delegate = nil; recorder.stop()
        let url = recorder.url
        self.recorder = nil; recording = false; stopClock()
        defer { try? FileManager.default.removeItem(at: url); deactivate() }
        do {
            let data = try Data(contentsOf: url)
            guard data.count > 44, data.count <= 2_000_000 else { throw CocoaError(.fileReadCorruptFile) }
            let recordedDuration = try AVAudioPlayer(data: data).duration
            guard recordedDuration.isFinite, recordedDuration > 0, recordedDuration <= 60 else { throw CocoaError(.fileReadCorruptFile) }
            duration = recordedDuration
            elapsed = 0
            recordedData = data; didRecord?(data)
        } catch {
            elapsed = player?.currentTime ?? 0; duration = player?.duration ?? 0
            self.error = "No se pudo conservar la grabación. Volvé a intentar."
        }
    }
    /// Cancelling a new take keeps the previous reviewed recording intact.
    func cancelRecording() {
        generation += 1; requestingPermission = false
        if let recorder {
            recorder.delegate = nil; recorder.stop()
            try? FileManager.default.removeItem(at: recorder.url)
        }
        recorder = nil; recording = false
        stopClock()
        elapsed = player?.currentTime ?? 0; duration = player?.duration ?? 0
        levels = Array(repeating: 0.05, count: 32)
        deactivate()
    }
    func prepare(_ data: Data) {
        guard playbackData != data else { return }
        stopAll(); needsMicrophoneSettings = false; error = nil
        do {
            let value = try AVAudioPlayer(data: data)
            guard value.duration.isFinite, value.duration > 0, value.prepareToPlay() else { throw CocoaError(.fileReadCorruptFile) }
            value.delegate = self; player = value; playbackData = data
            duration = value.duration; elapsed = 0
        } catch { self.error = "No se pudo leer el audio." }
    }
    func play(_ data: Data) {
        prepare(data)
        guard let player else { return }
        error = nil
        do {
            try activate(category: .playback, mode: .spokenAudio)
            if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
            guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
            playing = true; startClock()
        } catch { self.error = "No se pudo reproducir el audio."; pause() }
    }
    func pause() {
        player?.pause(); elapsed = player?.currentTime ?? elapsed; playing = false
        stopClock(); deactivate()
    }
    func seek(to fraction: Double) {
        guard fraction.isFinite, let player else { return }
        player.currentTime = min(1, max(0, fraction)) * player.duration
        elapsed = player.currentTime
    }
    func suspend() {
        if recording { finishRecording() }
        else if requestingPermission { cancelRecording() }
        else { pause() }
    }
    func stopAll() {
        generation += 1; requestingPermission = false
        if recorder != nil { finishRecording() }
        player?.stop(); player?.delegate = nil; player = nil; playbackData = nil; playing = false
        elapsed = 0; duration = 0
        stopClock(); deactivate()
    }
    private func activate(category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                          options: AVAudioSession.CategoryOptions = []) throws {
        if let owner = Self.sessionOwner, owner !== self { owner.suspend() }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(category, mode: mode, options: options)
        try session.setActive(true)
        Self.sessionOwner = self
    }
    private func deactivate() {
        // Preparing an idle row must not stop a different row's audio session.
        guard Self.sessionOwner === self else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        Self.sessionOwner = nil
    }
    private func handleInterruption() {
        guard recording || playing else { return }
        let wasRecording = recording
        suspend()
        if wasRecording { error = "Grabación interrumpida. Revisá el audio." }
        // Playback stays paused until another explicit tap, including unplugging headphones.
    }
    private func startClock() {
        stopClock()
        guard recording || playing else { return }
        let target = VoiceDisplayLinkTarget(self)
        let link = CADisplayLink(target: target, selector: #selector(VoiceDisplayLinkTarget.update(_:)))
        let maximum = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.screen.maximumFramesPerSecond ?? 60
        let preferred = Float(min(120, max(1, maximum)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, preferred), maximum: preferred, preferred: preferred)
        display.link = link
        link.add(to: .main, forMode: .common)
    }
    private func stopClock() {
        display.link?.invalidate(); display.link = nil
        meterCadence = VoiceMeterCadence()
    }
    fileprivate func updateDisplay(_ link: CADisplayLink) {
        guard recording || playing else { stopClock(); return }
        // Audio time remains authoritative; missed frames never change duration or playback speed.
        elapsed = recorder?.currentTime ?? player?.currentTime ?? 0
        if let recorder, meterCadence.shouldSample(at: link.targetTimestamp) {
            recorder.updateMeters()
            let level = min(1, max(0.05, pow(10, Double(recorder.averagePower(forChannel: 0)) / 40)))
            levels = Array(levels.dropFirst()) + [level]
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
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.finishRecording(); self.error = "No se pudo terminar la grabación. Revisá el audio o grabá otra vez."
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.pause(); self.error = "No se pudo leer el audio. Volvé a cargarlo."
        }
    }
}
