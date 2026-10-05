import AVFoundation
import PairNotesCore
import SwiftUI

struct VoiceWaveformView: View {
    let data: Data
    var progress: Double = 0
    @State private var levels: [Double] = []
    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, value in
                Capsule().fill(Color.accentColor.opacity(Double(index) / Double(max(1, levels.count)) < progress ? 1 : 0.35))
                    .frame(maxWidth: .infinity).frame(height: max(3, 32 * value))
            }
        }.frame(height: 36).accessibilityHidden(true)
            .task(id: data) {
                let bytes = data
                let computed = await Task.detached(priority: .utility) { VoiceWaveform.levels(bytes) }.value
                guard !Task.isCancelled else { return }
                levels = computed
            }
    }
}

/// Shared review and listening controls. Scrubbing never starts audio unexpectedly.
struct VoicePlaybackControls: View {
    @ObservedObject var player: VoiceNoteController
    let data: Data
    var title = "Tu nota de voz"
    private func time(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.subheadline.weight(.semibold))
            HStack(spacing: 14) {
                Button {
                    if player.playing { player.pause() } else { player.play(data) }
                } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill")
                        .font(.title3).frame(width: 48, height: 48)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(player.playing ? "Pausar audio" : "Reproducir audio")
                VStack(spacing: 0) {
                    VoiceWaveformView(data: data, progress: player.duration > 0 ? player.elapsed / player.duration : 0)
                    Slider(value: Binding(get: { player.duration > 0 ? player.elapsed / player.duration : 0 },
                                          set: { player.seek(to: $0) }), in: 0...1)
                        .accessibilityLabel("Posición del audio")
                        .accessibilityValue("\(time(player.elapsed)) de \(time(player.duration))")
                }
            }
            HStack {
                Text(time(player.elapsed))
                Spacer()
                Text(time(player.duration))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let error = player.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
        .task(id: data) { player.prepare(data) }
    }
}

struct VoiceRecordingMeter: View {
    @ObservedObject var controller: VoiceNoteController
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label("Grabando", systemImage: "record.circle.fill").foregroundStyle(.red)
                Spacer()
                Text(String(format: "0:%02d / 1:00", Int(controller.elapsed)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.subheadline.weight(.medium))
            HStack(spacing: 3) {
                ForEach(controller.levels.indices, id: \.self) { index in
                    Capsule().fill(Color.accentColor)
                        .frame(maxWidth: .infinity)
                        .frame(height: max(3, 42 * controller.levels[index]))
                }
            }.frame(height: 46).accessibilityHidden(true)
            Button("Terminar y escuchar", systemImage: "stop.circle.fill") { controller.finishRecording() }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Text("Hasta un minuto. Podés escucharla antes de enviar.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
    }
}

struct LetterVoicePlayer: View {
    @ObservedObject var services: AppServices
    let letter: TimeCapsuleLetter
    @StateObject private var player = VoiceNoteController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var data: Data?
    @State private var loadedKey: String?
    @State private var visible = true
    @State private var loading = false
    @State private var error: String?
    private var key: String { services.privateImageKey("voice:" + letter.id + (letter.audio?.id ?? "")) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProfileAvatarView(services: services, uid: letter.authorId,
                    name: services.coupleSpace?.profiles.first(where: { $0.uid == letter.authorId })?.displayName ?? "Tu pareja",
                    reference: services.coupleSpace?.profiles.first(where: { $0.uid == letter.authorId })?.avatar, size: 38)
                Text("Un poquito de su voz").font(.system(.headline, design: .serif))
            }
            if loadedKey == key, let data {
                VoicePlaybackControls(player: player, data: data, title: "Guardada para vos")
            } else {
                Button(action: loadAndPlay) {
                    Label(loading ? "Cargando audio…" : "Escuchar nota de voz", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.bordered).disabled(loading)
                if loading { ProgressView() }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(18)
        .background(services.personalization.theme.card, in: RoundedRectangle(cornerRadius: 22))
        .onChange(of: key) { _, _ in player.stopAll(); data = nil; loadedKey = nil }
        .onChange(of: scenePhase) { _, phase in if phase != .active { player.suspend() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in player.suspend() }
        .onAppear { visible = true }
        .onDisappear { visible = false; player.stopAll() }
    }
    private func loadAndPlay() {
        guard !loading else { return }
        let captured = key; loading = true; error = nil
        Task { @MainActor in
            defer { loading = false }
            do {
                let bytes = try await services.letterAsset(letter, role: "audio")
                guard visible, captured == key, scenePhase == .active else { return }
                data = bytes; loadedKey = captured; player.play(bytes)
            } catch { if captured == key { self.error = "No se pudo cargar el audio. Tocá para reintentar." } }
        }
    }
}
