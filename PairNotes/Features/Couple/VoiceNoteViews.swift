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
        HStack(spacing: 12) {
            ProfileAvatarView(services: services, uid: letter.authorId,
                name: services.coupleSpace?.profiles.first(where: { $0.uid == letter.authorId })?.displayName ?? "Tu pareja",
                reference: services.coupleSpace?.profiles.first(where: { $0.uid == letter.authorId })?.avatar, size: 38)
            Button {
                if player.playing { player.stopAll() }
                else if loadedKey == key, let data { player.play(data) }
                else { loadAndPlay() }
            } label: { Image(systemName: player.playing ? "stop.circle.fill" : "play.circle.fill").font(.largeTitle) }
                .disabled(loading).accessibilityLabel(player.playing ? "Detener audio" : "Escuchar su voz")
            VStack(alignment: .leading, spacing: 5) {
                if loadedKey == key, let data { VoiceWaveformView(data: data, progress: player.duration > 0 ? player.elapsed / player.duration : 0) }
                else { Text("Un poquito de su voz").font(.subheadline) }
                if loading { ProgressView("Cargando audio…") }
                Text("\(Int(player.playing ? player.elapsed : letter.audio?.duration ?? 0)) s").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let error = error ?? player.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .onChange(of: key) { _, _ in player.stopAll(); data = nil; loadedKey = nil }
        .onChange(of: scenePhase) { _, phase in if phase != .active { player.stopAll() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in player.stopAll() }
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
