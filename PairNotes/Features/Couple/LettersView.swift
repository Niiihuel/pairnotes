import PairNotesCore
import SwiftUI

struct LettersView: View {
    @ObservedObject var services: AppServices
    let notes: [RemoteNote]
    var catalog: DraftCatalogStore? = nil
    var focusID: String? = nil
    @State private var handledFocus = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var letters: [TimeCapsuleLetter] = []
    @State private var localDraftID: String?
    @State private var selected: TimeCapsuleLetter?
    @State private var composing = false
    @State private var filter = "received"
    @State private var error: String?
    @State private var loading = false
    private var key: String { services.privateImageKey("letters") }
    private var visible: [TimeCapsuleLetter] {
        letters.filter { (filter == "received" ? $0.recipientId == services.identity?.uid : $0.authorId == services.identity?.uid) && !($0.status == "draft" && $0.id == localDraftID) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Palabras para su momento").font(.system(.largeTitle, design: .serif).weight(.medium))
                Text("Un aniversario, un cumpleaños o un día elegido porque sí.").font(.subheadline).foregroundStyle(.secondary)
                Picker("Cartas", selection: $filter) { Text("Para vos").tag("received"); Text("Tus cartas").tag("sent") }.pickerStyle(.segmented)
                if loading && letters.isEmpty { ProgressView("Buscando sus cartas…") }
                if filter == "sent", localDraftID != nil {
                    Button { composing = true } label: {
                        Label("Retomar tu borrador privado", systemImage: "envelope.badge")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                            .background(services.personalization.theme.paper, in: RoundedRectangle(cornerRadius: 22))
                    }.buttonStyle(.plain)
                }
                if !loading && visible.isEmpty && (filter != "sent" || localDraftID == nil) {
                    ContentUnavailableView(filter == "received" ? "Un lugar para sus cartas" : "Tu próxima sorpresa",
                        systemImage: "envelope", description: Text(filter == "received" ? "Las cartas que te escriba tu pareja van a esperar acá, hasta su momento especial." : "Escribí una carta, sumale una foto o tu voz y elegí cuándo podrá abrirla."))
                    Button(localDraftID == nil ? "Escribir una carta" : "Retomar mi borrador", systemImage: "square.and.pencil") { composing = true }
                        .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                }
                ForEach(visible) { letter in
                    Button { selected = letter } label: { LetterEnvelope(services: services, letter: letter) }
                        .buttonStyle(.plain)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }.padding(20)
        }.background(services.personalization.theme.canvas)
        .navigationTitle("Cartitas").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button(localDraftID == nil ? "Escribir carta" : "Retomar borrador", systemImage: "square.and.pencil") { composing = true } } }
        .refreshable { await refresh() }
        .sheet(isPresented: $composing, onDismiss: { Task { await refresh() } }) {
            LetterComposer(services: services, notes: notes, catalog: catalog)
        }
        .sheet(item: $selected, onDismiss: { Task { await refresh() } }) { letter in
            if letter.status == "draft" { LetterComposer(services: services, notes: notes, catalog: catalog, original: letter) }
            else { LetterDetailView(services: services, original: letter) }
        }
        .task(id: key) {
            letters = []; selected = nil
            repeat {
                if scenePhase == .active { await refresh() }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            } while !Task.isCancelled
        }
        .onChange(of: services.identity?.uid) { _, _ in composing = false; selected = nil; letters = []; dismiss() }
        .onChange(of: services.membership?.id) { _, _ in composing = false; selected = nil; letters = []; dismiss() }
    }
    private func refresh() async {
        guard !loading else { return }
        let stored: LetterComposition? = MemoryCompositionStorage(key: services.privateImageKey("letter-composition:new")).loadValue()
        localDraftID = stored?.id
        let captured = key; loading = true
        defer { loading = false }
        do {
            let values = try await services.letters()
            guard !Task.isCancelled, captured == key else { return }
            letters = values; error = nil
            if !handledFocus, let focusID, let target = values.first(where: { $0.id == focusID }) {
                handledFocus = true; selected = target
            }
        } catch { if !Task.isCancelled, captured == key { self.error = "No se pudieron actualizar las cartas. Deslizá para reintentar." } }
    }
}

struct LetterEnvelope: View {
    @ObservedObject var services: AppServices
    let letter: TimeCapsuleLetter
    private var theme: CoupleTheme { services.personalization.theme }
    private var recipient: String {
        services.personalization.name(for: letter.recipientId, fallback: services.coupleSpace?.profiles.first(where: { $0.uid == letter.recipientId })?.displayName ?? "vos")
    }
    private var author: String {
        let profile = services.coupleSpace?.profiles.first { $0.uid == letter.authorId }
        return services.personalization.name(for: letter.authorId, fallback: profile?.displayName ?? "Tu pareja")
    }
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: letter.status == "draft" ? "envelope.badge" :
                letter.openedAt != nil || (letter.recipientId == services.identity?.uid && letter.canOpen) ?
                "envelope.open" : "envelope.badge.shield.half.filled")
                .font(.system(size: 44, weight: .light)).foregroundStyle(theme.accent)
            Text("Para \(recipient)")
                .font(.caption).foregroundStyle(.secondary)
            Text(letter.status == "draft" ? "Carta en borrador" : "De \(author), con cariño")
                .font(.system(.title3, design: .serif))
            if letter.status == "draft" {
                Text("Sólo vos podés verla · seguí escribiendo").font(.subheadline)
            } else if letter.openedAt != nil {
                Label("Ya abierta · volver a leer", systemImage: "heart.text.clipboard").font(.subheadline)
            } else if letter.authorId == services.identity?.uid {
                Text("Enviada con cariño").font(.subheadline.bold())
                Text("Se abre el " + letter.opensAt.formatted(date: .long, time: .shortened))
                    .font(.footnote).multilineTextAlignment(.center)
            } else if letter.canOpen { Text("Tu sorpresa está lista para abrir").font(.subheadline.bold()) }
            else {
                Text("Para el \(letter.opensAt.formatted(date: .long, time: .shortened))")
                    .font(.subheadline).multilineTextAlignment(.center)
            }
            Text(letter.openedAt == nil ? "♡" : "Abierta con cariño ♡").font(.caption).foregroundStyle(theme.accent)
        }
        .padding(28).frame(maxWidth: .infinity).foregroundStyle(theme.ink)
        .background(theme.paper, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(theme.accent.opacity(0.2), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

struct LetterDetailView: View {
    @ObservedObject var services: AppServices
    let original: TimeCapsuleLetter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
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
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let letter = opened {
                        Text(letter.title ?? "Una carta para vos").font(.system(.largeTitle, design: .serif))
                        if let photo {
                            Image(uiImage: photo).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 18))
                                .privacySensitive().onTapGesture { expandedPhoto = SelectedPhotoCrop(image: photo) }
                        }
                        if let body = letter.body, !body.isEmpty { Text(body).font(.system(.body, design: .serif)).lineSpacing(8).privacySensitive().textSelection(.enabled) }
                        if let drawing { Image(uiImage: drawing).resizable().scaledToFit().privacySensitive() }
                        if let note { AsyncNoteImage(path: note.assets.final, services: services).aspectRatio(1, contentMode: .fit) }
                        if letter.audio != nil { LetterVoicePlayer(services: services, letter: letter) }
                        Text("Guardada para este momento, escrita con amor.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        LetterEnvelope(services: services, letter: original)
                        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                            let available = original.authorId == services.identity?.uid || original.canOpen || context.date >= original.opensAt
                            Button(original.authorId == services.identity?.uid ? "Ver lo que escribiste" : available ? "Abrir mi carta" : "Esperando su momento",
                                   systemImage: available ? "envelope.open" : "lock") { open() }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                                .frame(maxWidth: .infinity).disabled(busy || !available)
                        }
                        if !original.canOpen && original.authorId != services.identity?.uid {
                            Text("Su contenido se guarda en secreto hasta la fecha elegida.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if busy { ProgressView("Abriendo con cariño…") }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                        if opened != nil { Button("Volver a cargar adjuntos") { open() }.disabled(busy) }
                    }
                }.padding(24)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: opened != nil)
            }.background(services.personalization.theme.canvas)
            .navigationTitle("Una cartita").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Listo") { dismiss() } } }
            .sensoryFeedback(.impact(weight: .light, intensity: 0.5), trigger: feedback)
            .onChange(of: key) { _, _ in opened = nil; photo = nil; drawing = nil; note = nil; dismiss() }
            .sheet(item: $expandedPhoto) { PhotoViewer(image: $0.image) }
            .onAppear { visible = true }
            .onDisappear { visible = false }
        }
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
