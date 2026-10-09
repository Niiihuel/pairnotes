import PairNotesCore
import SwiftUI

struct LettersView: View {
    @ObservedObject var services: AppServices
    let notes: [RemoteNote]
    var catalog: DraftCatalogStore? = nil
    var focusID: String? = nil
    @State private var handledFocus = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.coupleModalControl) private var modalControl
    @State private var modalOwner = UUID()
    @State private var letters: [TimeCapsuleLetter] = []
    @State private var loadedScope: String?
    @State private var draftScope: String?
    @State private var requestID = UUID()
    @State private var localDraftID: String?
    @State private var localDraftTitle = ""
    @State private var selected: TimeCapsuleLetter?
    @State private var composing = false
    @State private var filter = "received"
    @State private var error: String?
    @State private var loading = false
    private var key: String { services.privateImageKey("letters") }
    private var hasLocalDraft: Bool { draftScope == key && localDraftID != nil }
    private var visible: [TimeCapsuleLetter] {
        guard loadedScope == key else { return [] }
        return letters.filter { (filter == "received" ? $0.recipientId == services.identity?.uid : $0.authorId == services.identity?.uid) && !(hasLocalDraft && $0.status == "draft" && $0.id == localDraftID) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Cartas", selection: $filter) { Text("Para vos").tag("received"); Text("Tus cartas").tag("sent") }.pickerStyle(.segmented)
                if loading && letters.isEmpty { ProgressView("Cargando…") }
                if filter == "sent", hasLocalDraft {
                    Button(action: beginComposition) {
                        LetterEnvelopePaper {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Borrador").font(.caption.weight(.medium))
                                Text(localDraftTitle.isEmpty ? "Tu próxima carta" : localDraftTitle)
                                    .font(.system(.title3, design: .serif))
                                Label("Seguir escribiendo", systemImage: "pencil").font(.subheadline)
                            }
                        }
                    }.buttonStyle(.plain)
                }
                if !loading && visible.isEmpty && (filter != "sent" || !hasLocalDraft) {
                    ContentUnavailableView(filter == "received" ? "Todavía no hay cartas" : "Tu próxima carta",
                        systemImage: "envelope")
                    Button(hasLocalDraft ? "Retomar mi borrador" : "Escribir una carta", systemImage: "square.and.pencil", action: beginComposition)
                        .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                        .foregroundStyle(colorScheme == .dark ? LetterStationeryPalette(dark: true).canvas : .white)
                }
                ForEach(visible) { letter in
                    Button { selectLetter(letter) } label: { LetterEnvelope(services: services, letter: letter) }
                        .buttonStyle(.plain)
                }
                if draftScope == key, let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }.padding(20)
        }.coupleScreenBackground()
        .navigationTitle("Cartas").navigationBarTitleDisplayMode(.inline)
        .tint(LetterStationeryPalette(dark: colorScheme == .dark).accent)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button(hasLocalDraft ? "Retomar borrador" : "Escribir carta", systemImage: "square.and.pencil", action: beginComposition) } }
        .refreshable { await refresh() }
        .sheet(isPresented: $composing, onDismiss: { modalControl.onDismissed(modalOwner); Task { await refresh() } }) {
            LetterComposer(services: services, notes: notes, catalog: catalog)
        }
        .sheet(item: $selected, onDismiss: { modalControl.onDismissed(modalOwner); Task { await refresh() } }) { letter in
            if letter.status == "draft" { LetterComposer(services: services, notes: notes, catalog: catalog, original: letter) }
            else { LetterDetailView(services: services, original: letter) }
        }
        .task(id: key) {
            requestID = UUID(); loading = false; loadedScope = nil; draftScope = nil
            letters = []; localDraftID = nil; localDraftTitle = ""; error = nil; handledFocus = false
            composing = false; selected = nil
            repeat {
                if scenePhase == .active { await refresh() }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            } while !Task.isCancelled
        }
        .onChange(of: services.identity?.uid) { _, _ in composing = false; selected = nil; letters = [] }
        .onChange(of: services.membership?.id) { _, _ in composing = false; selected = nil; letters = [] }
        .onChange(of: composing) { _, presented in if presented { modalControl.onPresented(modalOwner) } }
        .onChange(of: selected?.id) { _, id in if id != nil { modalControl.onPresented(modalOwner) } }
        .onChange(of: modalControl.dismissalVersion) { _, _ in composing = false; selected = nil }
    }
    private func beginComposition() {
        modalControl.onPresented(modalOwner)
        composing = true
    }
    private func selectLetter(_ letter: TimeCapsuleLetter) {
        guard loadedScope == key, letters.contains(where: { $0.id == letter.id }) else { return }
        modalControl.onPresented(modalOwner)
        selected = letter
    }
    private func refresh() async {
        guard !loading else { return }
        let captured = key, request = UUID()
        requestID = request; loading = true
        let stored: LetterComposition? = MemoryCompositionStorage(key: services.privateImageKey("letter-composition:new")).loadValue()
        draftScope = captured
        localDraftID = stored?.id
        localDraftTitle = stored?.title ?? ""
        defer { if requestID == request { loading = false } }
        do {
            let values = try await services.letters()
            guard !Task.isCancelled, captured == key, requestID == request else { return }
            letters = values; loadedScope = captured; error = nil
            if !handledFocus, let focusID, let target = values.first(where: { $0.id == focusID }) {
                handledFocus = true; selectLetter(target)
            }
        } catch {
            if !Task.isCancelled, captured == key, requestID == request {
                self.error = "No se pudieron actualizar las cartas. Deslizá para reintentar."
            }
        }
    }
}

struct LetterEnvelope: View {
    @ObservedObject var services: AppServices
    let letter: TimeCapsuleLetter
    @Environment(\.colorScheme) private var colorScheme
    private var recipient: String {
        services.personalization.name(for: letter.recipientId, fallback: services.coupleSpace?.profiles.first(where: { $0.uid == letter.recipientId })?.displayName ?? "vos")
    }
    private var author: String {
        let profile = services.coupleSpace?.profiles.first { $0.uid == letter.authorId }
        return services.personalization.name(for: letter.authorId, fallback: profile?.displayName ?? "Tu pareja")
    }
    var body: some View {
        let palette = LetterStationeryPalette(dark: colorScheme == .dark)
        LetterEnvelopePaper(opened: letter.openedAt != nil) {
            VStack(alignment: .leading, spacing: 12) {
                Text(letter.authorId == services.identity?.uid ? "Para \(recipient)" : "De \(author)")
                    .font(.system(.title3, design: .serif))
                if letter.status == "draft" {
                    Label("Borrador", systemImage: "pencil").font(.subheadline)
                } else if letter.openedAt != nil {
                    Label("Volver a leer", systemImage: "envelope.open").font(.subheadline)
                } else if letter.authorId == services.identity?.uid {
                    Text("Enviada").font(.subheadline).foregroundStyle(palette.secondaryInk)
                } else if letter.canOpen {
                    Label("Lista para abrir", systemImage: "envelope.open").font(.subheadline.weight(.medium))
                } else {
                    Label("Sobre cerrado", systemImage: "lock").font(.subheadline)
                }
                if letter.openedAt == nil && letter.status != "draft" {
                    Text(letter.opensAt, format: .dateTime.day().month(.wide).hour().minute())
                        .font(.caption).foregroundStyle(palette.secondaryInk)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct LetterDetailView: View {
    @ObservedObject var services: AppServices
    let original: TimeCapsuleLetter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var opened: TimeCapsuleLetter?
    @State private var drawing: UIImage?
    @State private var photo: UIImage?
    @State private var note: RemoteNote?
    @State private var busy = false
    @State private var error: String?
    @State private var feedback = 0
    @State private var expandedPhoto: SelectedPhotoCrop?
    @State private var visible = true
    private var key: String { services.privateImageKey("letter:" + original.id) }
    private var stationery: LetterStationeryPalette { LetterStationeryPalette(dark: colorScheme == .dark) }
    private var authorName: String {
        let profile = services.coupleSpace?.profiles.first { $0.uid == original.authorId }
        let fallback = profile?.displayName ?? (original.authorId == services.identity?.uid ? services.identity?.displayName : nil) ?? "Tu pareja"
        return services.personalization.name(for: original.authorId, fallback: fallback)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let letter = opened {
                        LetterPaper(ruled: false) {
                            VStack(alignment: .leading, spacing: 24) {
                                Text(letter.title ?? "Para vos,").font(.system(.title, design: .serif).weight(.semibold))
                                    .foregroundStyle(stationery.accent).privacySensitive().accessibilityAddTraits(.isHeader)
                                Rectangle().fill(stationery.fold.opacity(0.3)).frame(height: 1)
                                    .accessibilityHidden(true)
                                if let body = letter.body, !body.isEmpty {
                                    Text(body).font(.system(.body, design: .serif)).lineSpacing(8)
                                        .privacySensitive().textSelection(.enabled)
                                }
                                if let photo {
                                    Button { expandedPhoto = SelectedPhotoCrop(image: photo) } label: {
                                        Image(uiImage: photo).resizable().scaledToFit()
                                            .padding(8).background(stationery.paper).privacySensitive()
                                    }.buttonStyle(.plain).accessibilityLabel("Ver foto adjunta")
                                }
                                if let drawing { Image(uiImage: drawing).resizable().scaledToFit().privacySensitive().accessibilityLabel("Dibujo adjunto") }
                                if let note { AsyncNoteImage(path: note.assets.final, services: services).aspectRatio(1, contentMode: .fit) }
                                if letter.audio != nil { LetterVoicePlayer(services: services, letter: letter) }
                                Text(authorName).font(.system(.title3, design: .serif).italic())
                                    .foregroundStyle(stationery.accent).accessibilityLabel("De " + authorName)
                            }
                        }
                    } else {
                        LetterEnvelope(services: services, letter: original)
                        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                            let available = original.authorId == services.identity?.uid || original.canOpen || context.date >= original.opensAt
                            Button(original.authorId == services.identity?.uid ? "Leer carta" : available ? "Abrir carta" : "Todavía no se puede abrir",
                                   systemImage: available ? "envelope.open" : "lock") { open() }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                                .foregroundStyle(colorScheme == .dark ? stationery.canvas : .white)
                                .frame(maxWidth: .infinity).disabled(busy || !available)
                        }
                    }
                    if busy { ProgressView("Abriendo…") }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                        if opened != nil { Button("Volver a cargar adjuntos") { open() }.disabled(busy) }
                    }
                }.frame(maxWidth: 640).padding(20).frame(maxWidth: .infinity)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: opened != nil)
            }.coupleScreenBackground()
            .navigationTitle("Carta").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Listo") { dismiss() } } }
            .sensoryFeedback(.impact(weight: .light, intensity: 0.5), trigger: feedback)
            .onChange(of: key) { _, _ in opened = nil; photo = nil; drawing = nil; note = nil; expandedPhoto = nil; dismiss() }
            .sheet(item: $expandedPhoto) { PhotoViewer(image: $0.image) }
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .task { if original.openedAt != nil || original.authorId == services.identity?.uid { open() } }
        }.tint(stationery.accent)
    }
    private func open() {
        guard !busy else { return }
        let captured = key; busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let letter = try await services.openLetter(id: original.id)
                guard visible, captured == key, scenePhase == .active else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) { opened = letter; feedback += 1 }
                if letter.photo != nil {
                    let data = try await services.letterAsset(letter, role: "photo")
                    guard visible, captured == key else { return }; photo = UIImage(data: data)
                }
                if letter.drawing != nil {
                    let data = try await services.letterAsset(letter, role: "drawing")
                    guard visible, captured == key else { return }; drawing = UIImage(data: data)
                }
                if let id = letter.noteId {
                    let fetched = try await services.note(id: id)
                    guard visible, captured == key else { return }; note = fetched
                }
            } catch {
                guard visible, captured == key else { return }
                self.error = opened == nil ? "Todavía no pudimos abrirla. Revisá la fecha de apertura y la conexión." : "La carta está abierta; falta cargar algún adjunto. Podés reintentar."
            }
        }
    }
}
