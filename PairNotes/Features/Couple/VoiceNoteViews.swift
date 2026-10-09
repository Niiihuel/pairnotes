import AVFoundation
import AVKit
import PairNotesCore
import SwiftUI
import UIKit

private enum VoiceTime {
    static func label(_ value: Double) -> String {
        let seconds = Int(value.isFinite ? min(3_600, max(0, value)) : 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Shows only audio the server has made available to this account.
struct VoiceNotesView: View {
    @ObservedObject var services: AppServices
    let notes: [RemoteNote]
    var catalog: DraftCatalogStore? = nil
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.coupleModalControl) private var modalControl
    @State private var letters: [TimeCapsuleLetter] = []
    @State private var selection = "received"
    @State private var composing = false
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var modalOwner = UUID()
    @State private var hasAudioDraft = false
    @State private var loadedScope: String?
    @State private var draftScope: String?
    private var scope: String { services.privateImageKey("voice-notes") }
    private var visible: [TimeCapsuleLetter] {
        guard loadedScope == scope else { return [] }
        let uid = services.identity?.uid
        return letters.filter {
            $0.status == "sealed" && $0.audio != nil && ($0.canOpen || $0.authorId == uid) &&
                (selection == "received" ? $0.recipientId == uid : $0.authorId == uid)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        List {
            Section {
                Picker("Audios", selection: $selection) {
                    Text("Recibidos").tag("received")
                    Text("Enviados").tag("sent")
                }.pickerStyle(.segmented)
            }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            if loading && letters.isEmpty {
                ProgressView("Cargando audios…").frame(maxWidth: .infinity)
            } else if visible.isEmpty {
                ContentUnavailableView(selection == "received" ? "Sin audios recibidos" : "Sin audios enviados",
                    systemImage: "waveform", description: Text(selection == "received" ? "Los audios disponibles de tu pareja aparecerán acá." : "Grabá un audio para tu pareja."))
                    .listRowBackground(Color.clear)
            }
            ForEach(visible) { letter in
                LetterVoicePlayer(services: services, letter: letter)
                    .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if let error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary)
                    Button("Reintentar") { Task { await refresh() } }.disabled(loading)
                }.listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .coupleScreenBackground()
        .navigationTitle("Audios")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(hasAudioDraft && draftScope == scope ? "Retomar audio" : "Grabar", systemImage: "mic.fill", action: openComposer)
            }
        }
        .refreshable { await refresh() }
        .sheet(isPresented: $composing, onDismiss: {
            modalControl.onDismissed(modalOwner)
            Task { await refresh() }
        }) {
            LetterComposer(services: services, notes: notes, catalog: catalog, startsWithVoice: true)
        }
        .task(id: scope) {
            requestID = UUID(); loading = false; letters = []; error = nil; hasAudioDraft = false; loadedScope = nil; draftScope = nil
            repeat {
                if scenePhase == .active { await refresh() }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            } while !Task.isCancelled
        }
        .onChange(of: composing) { _, presented in
            if presented { modalControl.onPresented(modalOwner) }
        }
        .onChange(of: modalControl.dismissalVersion) { _, _ in composing = false }
        .onChange(of: scope) { _, _ in composing = false; letters = []; hasAudioDraft = false; loadedScope = nil; draftScope = nil }
    }

    private func openComposer() {
        guard services.membershipResolved, services.membership != nil else { return }
        modalControl.onPresented(modalOwner)
        composing = true
    }

    private func refresh() async {
        guard services.membershipResolved, services.membership != nil else { hasAudioDraft = false; draftScope = nil; return }
        let draft: LetterComposition? = MemoryCompositionStorage(key: services.privateImageKey("letter-composition:voice")).loadValue()
        hasAudioDraft = draft != nil
        draftScope = scope
        guard !loading else { return }
        let captured = scope, request = UUID()
        requestID = request; loading = true
        defer { if requestID == request { loading = false } }
        do {
            let result = try await services.letters()
            guard !Task.isCancelled, scope == captured, requestID == request else { return }
            letters = result; loadedScope = captured; error = nil
        } catch {
            guard !Task.isCancelled, scope == captured, requestID == request else { return }
            self.error = "No se pudieron cargar los audios."
        }
    }
}

struct VoiceWaveformView: View {
    let data: Data
    var progress: Double = 0
    @State private var levels: [Double] = []
    var body: some View {
        waveform.opacity(0.35)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    waveform.mask(alignment: .leading) {
                        Rectangle().frame(width: geometry.size.width * min(1, max(0, progress.isFinite ? progress : 0)))
                    }
                }
            }
            .frame(height: 36).accessibilityHidden(true)
            .task(id: data) {
                let bytes = data
                let computed = await Task.detached(priority: .utility) { VoiceWaveform.levels(bytes) }.value
                guard !Task.isCancelled else { return }
                levels = computed
            }
    }
    private var waveform: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, value in
                Capsule().fill(Color.accentColor)
                    .frame(maxWidth: .infinity).frame(height: max(3, 32 * value))
            }
        }.frame(height: 36)
    }
}

/// Shared review and listening controls. Scrubbing never starts audio unexpectedly.
struct VoicePlaybackControls: View {
    @ObservedObject var player: VoiceNoteController
    let data: Data
    var title = "Tu audio"
    var displaysNotice = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty { Text(title).font(.subheadline.weight(.semibold)) }
            HStack(spacing: 14) {
                Button {
                    if player.playing { player.pause() } else { player.play(data) }
                } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill")
                        .font(.title3).frame(width: 32, height: 32)
                }.buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
                    .disabled(player.duration <= 0)
                    .accessibilityLabel(player.playing ? "Pausar audio" : "Reproducir audio")
                VStack(spacing: 0) {
                    VoiceWaveformView(data: data, progress: player.duration > 0 ? player.elapsed / player.duration : 0)
                    Slider(value: Binding(get: { player.duration > 0 ? player.elapsed / player.duration : 0 },
                                          set: { player.seek(to: $0) }), in: 0...1)
                        .accessibilityLabel("Posición del audio")
                        .disabled(player.duration <= 0)
                        .accessibilityValue("\(VoiceTime.label(player.elapsed)) de \(VoiceTime.label(player.duration))")
                }
                VoiceAudioRoutePicker().frame(width: 44, height: 44)
            }
            HStack {
                Text(VoiceTime.label(player.elapsed))
                Spacer()
                Text(VoiceTime.label(player.duration))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if displaysNotice { VoiceControllerNotice(controller: player) }
        }
        .task(id: data) { player.prepare(data) }
    }
}

struct VoiceRecordingMeter: View {
    @ObservedObject var controller: VoiceNoteController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label("Grabando", systemImage: "record.circle.fill").foregroundStyle(.red)
                Spacer()
                Text("\(VoiceTime.label(controller.elapsed)) / 1:00")
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.subheadline.weight(.medium))
            HStack(spacing: 3) {
                ForEach(controller.levels.indices, id: \.self) { index in
                    Capsule().fill(Color.accentColor)
                        .frame(maxWidth: .infinity)
                        .frame(height: max(3, 42 * controller.levels[index]))
                }
            }.frame(height: 46).accessibilityHidden(true)
                .animation(reduceMotion ? nil : .linear(duration: VoiceMeterCadence.interval), value: controller.levels)
            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Button("Cancelar", role: .cancel) { controller.cancelRecording() }
                    .buttonStyle(.bordered).controlSize(.large)
                Button("Detener", systemImage: "stop.fill") { controller.finishRecording() }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
            }
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
    @State private var visible = false
    @State private var loading = false
    @State private var error: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var requestID = UUID()
    private var key: String { services.privateImageKey("voice:" + letter.id + (letter.audio?.id ?? "")) }
    private var authorName: String {
        if letter.authorId == services.identity?.uid { return "Vos" }
        let name = services.coupleSpace?.profiles.first(where: { $0.uid == letter.authorId })?.displayName ?? "Tu pareja"
        return services.personalization.name(for: letter.authorId, fallback: name)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProfileAvatarView(services: services, uid: letter.authorId,
                    name: services.coupleSpace?.profiles.first(where: { $0.uid == letter.authorId })?.displayName ?? "Tu pareja",
                    reference: services.coupleSpace?.profiles.first(where: { $0.uid == letter.authorId })?.avatar, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(authorName).font(.headline)
                    if letter.status == "draft" { Text("Borrador").font(.caption).foregroundStyle(.secondary) }
                    else if letter.authorId == services.identity?.uid, letter.opensAt > Date() {
                        Text("Se abre \(letter.opensAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(letter.opensAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if loadedKey != key, let duration = letter.audio?.duration {
                    Text(VoiceTime.label(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if loadedKey == key, let data {
                VoicePlaybackControls(player: player, data: data, title: "")
            } else {
                Button(action: loadAndPlay) {
                    if loading { ProgressView("Cargando audio…").frame(maxWidth: .infinity, minHeight: 44) }
                    else {
                        Label(error == nil ? "Reproducir" : "Reintentar", systemImage: "play.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }.buttonStyle(.bordered).disabled(loading)
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(18)
        .background(services.personalization.theme.card, in: RoundedRectangle(cornerRadius: 22))
        .privacySensitive()
        .onChange(of: key) { _, _ in cancelLoad(); player.stopAll(); data = nil; loadedKey = nil; error = nil }
        .onChange(of: scenePhase) { _, phase in if phase != .active { player.suspend() } }
        .onAppear { visible = true }
        .onDisappear { visible = false; cancelLoad(); player.stopAll() }
    }
    private func loadAndPlay() {
        guard !loading, scenePhase == .active else { return }
        let captured = key, request = UUID(); requestID = request; loading = true; error = nil
        loadTask = Task { @MainActor in
            defer { if requestID == request { loading = false; loadTask = nil } }
            do {
                let bytes = try await services.letterAsset(letter, role: "audio")
                guard !Task.isCancelled, visible, captured == key, requestID == request, scenePhase == .active else { return }
                data = bytes; loadedKey = captured; player.play(bytes)
            } catch { if !Task.isCancelled, visible, captured == key, requestID == request { self.error = "No se pudo cargar el audio." } }
        }
    }
    private func cancelLoad() { requestID = UUID(); loadTask?.cancel(); loadTask = nil; loading = false }
}

struct VoiceControllerNotice: View {
    @ObservedObject var controller: VoiceNoteController
    var body: some View {
        if let error = controller.error {
            VStack(alignment: .leading, spacing: 8) {
                Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary)
                if controller.needsMicrophoneSettings {
                    Button("Abrir Configuración") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }.buttonStyle(.bordered).frame(minHeight: 44)
                }
            }
        }
    }
}

private struct VoiceAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.accessibilityLabel = "Salida de audio"
        return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) { }
}
