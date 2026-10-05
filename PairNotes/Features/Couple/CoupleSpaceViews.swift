import SwiftUI
import PhotosUI
import ImageIO
import PairNotesCore
import EventKit
import EventKitUI

enum SelectedPhoto {
    /// Decode at a bounded size and re-encode without EXIF/location metadata.
    static func jpeg(_ data: Data, maximum: Int = 1_600) throws -> Data {
        guard data.count <= 30 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximum
              ] as CFDictionary),
              let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85),
              jpeg.count <= 5 * 1_024 * 1_024 else { throw ServiceError.invalidResponse }
        return jpeg
    }
}

struct SelectedPhotoCrop: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct TogetherSettingsView: View {
    @ObservedObject var services: AppServices
    @ObservedObject private var reminders = MonthlyReminderService.shared
    @State private var editing = false
    @State private var calendarSheet = false
    var body: some View {
        Form {
            Section {
                CouplePortraits(services: services)
                if let started = services.coupleSpace?.startedOn, let date = started.date(in: .current) {
                    LabeledContent("Juntos desde", value: date.formatted(date: .long, time: .omitted))
                    if let days = started.daysTogether(on: Date(), calendar: .current) {
                        Text("\(days) días de su historia").font(.title2.bold()).foregroundStyle(.pink)
                    }
                    Button("Editar fecha", systemImage: "pencil") { editing = true }
                    Button("Agregar aniversario al Calendario", systemImage: "calendar.badge.plus") { calendarSheet = true }
                } else { Button("Elegir nuestra fecha", systemImage: "calendar.badge.plus") { editing = true } }
            }
            Section {
                Toggle("Avisarme cada mes", isOn: Binding(get: { reminders.isEnabled(services: services) },
                    set: { enabled in Task { await reminders.setEnabled(enabled, services: services) } }))
                    .disabled(services.coupleSpace?.startedOn == nil || reminders.working)
            } footer: {
                Text("Opcional, en este iPhone. A las 9:00 del día que cumplen cada mes: 1, 2, 3… En meses más cortos, el aviso cae en el último día. Tu pareja puede activarlo por separado.")
            }
            if let error = reminders.errorMessage { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Nuestra fecha").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) { TogetherDateEditor(services: services) }
        .sheet(isPresented: $calendarSheet) {
            if let date = services.coupleSpace?.startedOn?.date(in: .current) {
                CalendarEventEditor(title: "Nuestro aniversario", date: date, recursYearly: true)
            }
        }
    }
}

struct ProfileAvatarView: View {
    @ObservedObject var services: AppServices
    let uid: String
    let name: String
    let reference: CoupleAvatar?
    var size: CGFloat = 56
    @State private var image: UIImage?
    @State private var loadedKey: String?
    private var key: String {
        [services.identity?.uid ?? "", services.membership?.id ?? "", String(services.membership?.pairEpoch ?? 0),
         uid, reference?.id ?? "", reference?.sha256 ?? ""].joined(separator: ":")
    }
    var body: some View {
        ZStack {
            Circle().fill(.pink.opacity(0.14))
            if loadedKey == key, let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.pink) }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 1))
        .accessibilityLabel("Foto de \(name)").privacySensitive()
        .task(id: key) {
            let captured = key; image = nil; loadedKey = nil
            guard let reference else { return }
            do {
                let bytes = try await services.avatar(uid: uid, reference: reference)
                guard !Task.isCancelled, key == captured else { return }
                image = UIImage(data: bytes); loadedKey = captured
            } catch { /* Initials remain visible if the private photo is unavailable. */ }
        }
    }
}

struct CouplePortraits: View {
    @ObservedObject var services: AppServices
    var body: some View {
        if let own = services.identity, let pair = services.membership {
            HStack(spacing: 18) {
                VStack(spacing: 6) {
                    ProfileAvatarView(services: services, uid: own.uid, name: own.displayName, reference: services.profileAvatar, size: 66)
                    Text(services.personalization.name(for: own.uid, fallback: own.displayName)).lineLimit(1).font(.subheadline.weight(.medium))
                }.frame(maxWidth: .infinity)
                Image(systemName: "heart.fill").font(.title2).foregroundStyle(.pink).accessibilityHidden(true)
                VStack(spacing: 6) {
                    ProfileAvatarView(services: services, uid: pair.partner.uid, name: pair.partner.displayName,
                        reference: services.coupleSpace?.profiles.first(where: { $0.uid == pair.partner.uid })?.avatar, size: 66)
                    Text(services.personalization.name(for: pair.partner.uid, fallback: pair.partner.displayName)).lineLimit(1).font(.subheadline.weight(.medium))
                }.frame(maxWidth: .infinity)
            }.padding(.vertical, 10)
        }
    }
}

struct DistanceSummary: View {
    let distance: CoupleDistance?
    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 3) {
                if let distance, let meters = distance.displayMeters(at: context.date) {
                    Text(meters < 1_000 ? "Aproximadamente \(Int(meters)) m" : "Aproximadamente \((meters / 1_000).formatted(.number.precision(.fractionLength(1)))) km")
                    if distance.displayStatus(at: context.date) == .stale {
                        Text("Última distancia · necesita actualizarse").font(.caption)
                    }
                } else {
                    Text(distance?.status == .disabled ? "Compartir distancia es opcional" : "Esperando una ubicación reciente de ambos")
                }
                if let date = distance?.updatedAt {
                    Text("Actualizada \(date.formatted(.relative(presentation: .named)))").font(.caption)
                }
            }.foregroundStyle(.secondary)
        }
    }
}

struct DistanceSettingsView: View {
    @ObservedObject var services: AppServices
    @ObservedObject private var location = LocationSharingController.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            Section { CouplePortraits(services: services); DistanceSummary(distance: services.coupleSpace?.location.distance) }
            Section {
                if location.isEnabledHere(services: services) {
                    Label("Compartís desde este iPhone", systemImage: "location.fill").foregroundStyle(.green)
                    Button("Actualizar ahora", systemImage: "arrow.clockwise") {
                        Task { await location.refreshIfNeeded(services: services, force: true) }
                    }.disabled(location.working)
                } else {
                    Button(services.coupleSpace?.location.sharingEnabled == true ? "Compartir desde este iPhone" : "Activar mi distancia",
                           systemImage: "location") { Task { await location.activate(services: services) } }.disabled(location.working)
                }
                if services.coupleSpace?.location.sharingEnabled == true {
                    Button("Pausar y borrar mi ubicación", systemImage: "location.slash", role: .destructive) {
                        Task { await location.pause(services: services) }
                    }
                }
            } footer: {
                Text("Cada uno decide si comparte. Se actualiza al usar la app y sólo se conserva la última ubicación para calcular una distancia aproximada. A los 30 minutos dejamos de mostrar el número. Tu pareja y el widget no reciben tus coordenadas.")
            }
            if location.working { ProgressView("Actualizando…") }
            if let message = location.message { Text(message).font(.footnote) }
            Section { Text("Agregá «Nuestra distancia» a la pantalla de bloqueo. iOS decide cuándo actualizar el widget.").font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Nuestra distancia").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
    }
}

struct TogetherDateEditor: View {
    @ObservedObject var services: AppServices
    @ObservedObject private var reminders = MonthlyReminderService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    private let initial: CoupleDate?
    @State private var dateTouched = false
    private let pairID: String?
    @State private var saving = false
    @State private var discard = false
    @State private var error: String?
    init(services: AppServices) {
        self.services = services
        initial = services.coupleSpace?.startedOn
        pairID = services.membership?.id
        _date = State(initialValue: initial?.date(in: .current) ?? .now)
    }
    private var value: CoupleDate? { CoupleDate(date: date, calendar: .current) }
    private var changed: Bool { initial == nil ? dateTouched : value != initial }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Juntos desde", selection: $date, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical).onChange(of: date) { _, _ in dateTouched = true }
                } footer: { Text("Esta fecha es compartida. Aparece en Inicio y en el widget «Juntos desde».") }
                Section {
                    Toggle("Avisarme cada mes", isOn: Binding(
                        get: { reminders.isEnabled(services: services) },
                        set: { enabled in Task { await reminders.setEnabled(enabled, services: services) } }))
                        .disabled(initial == nil || changed || saving || reminders.working)
                } footer: {
                    Text(initial == nil || changed ? "Guardá la fecha para activar los avisos mensuales." : "Un aviso en este iPhone a las 9:00 cuando cumplan 1, 2, 3 meses… Si el mes no tiene ese día, se usa su último día.")
                }
                if let text = error ?? reminders.errorMessage { Text(text).foregroundStyle(.red) }
            }
            .disabled(saving)
            .navigationTitle("Nuestra fecha").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { if changed { discard = true } else { dismiss() } }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Guardar") { save() }.disabled(saving || (initial != nil && !changed)) }
            }
            .interactiveDismissDisabled(saving || changed)
            .confirmationDialog("¿Descartar los cambios?", isPresented: $discard, titleVisibility: .visible) {
                Button("Descartar cambios", role: .destructive) { dismiss() }
                Button("Seguir editando", role: .cancel) {}
            }
        }
    }
    private func save() {
        guard let value, services.membership?.id == pairID, !saving else { return }
        saving = true; error = nil
        Task { @MainActor in
            defer { saving = false }
            do { try await services.updateStartedOn(value); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct MessageComposer: View {
    @ObservedObject var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    @State private var discard = false
    @State private var messageID = UUID()
    @State private var submittedText: String?
    @FocusState private var focused: Bool
    private let pairID: String?
    private let storage: MemoryCompositionStorage
    @State private var finished = false
    private struct Draft: Codable {
        let text: String
        let id: UUID
        let submittedText: String?
    }
    init(services: AppServices) {
        self.services = services; pairID = services.membership?.id
        let storage = MemoryCompositionStorage(key: services.privateImageKey("message-draft"))
        self.storage = storage
        let draft: Draft? = storage.loadValue()
        _text = State(initialValue: draft?.text ?? "")
        _messageID = State(initialValue: draft?.id ?? UUID())
        _submittedText = State(initialValue: draft?.submittedText)
    }
    private var clean: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Algo que quieras decirle…", text: $text, axis: .vertical).lineLimit(5...12).focused($focused)
                    HStack { Spacer(); Text("\(text.utf16.count)/500").font(.caption).foregroundStyle(text.utf16.count > 500 ? .red : .secondary) }
                } header: { Text("Para \(services.membership?.partner.displayName ?? "tu pareja")") } footer: {
                    Text("Tu pareja podrá leerlo en la app y en su widget «Tu mensaje».")
                }
                if let error { Text(error).foregroundStyle(.red) }
                if sending { ProgressView("Enviando…") }
            }
            .disabled(sending)
            .navigationTitle("Un mensaje").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { if clean.isEmpty { finished = true; storage.clear(); dismiss() } else { discard = true } }.disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enviar", systemImage: "paperplane.fill") { send() }.disabled(sending || clean.isEmpty || text.utf16.count > 500)
                }
            }
            .interactiveDismissDisabled(sending || !clean.isEmpty)
            .confirmationDialog("Tu mensaje todavía no está enviado", isPresented: $discard, titleVisibility: .visible) {
                Button("Guardar borrador y salir") { if persistMessage() { dismiss() } }
                Button("Descartar", role: .destructive) { finished = true; storage.clear(); dismiss() }
                Button("Seguir escribiendo", role: .cancel) {}
            }
            .onChange(of: text) { _, _ in _ = persistMessage() }
            .onDisappear { if !finished { _ = persistMessage() } }
            .task { focused = true }
        }
    }
    private func persistMessage() -> Bool {
        guard !finished else { return true }
        do { try storage.saveValue(Draft(text: text, id: messageID, submittedText: submittedText)); return true }
        catch { self.error = "No se pudo guardar el borrador en este iPhone."; return false }
    }
    private func send() {
        guard !sending, !clean.isEmpty, text.utf16.count <= 500, services.membership?.id == pairID,
              storage.key == services.privateImageKey("message-draft") else { return }
        if let submittedText, submittedText != clean { messageID = UUID() }
        submittedText = clean
        guard persistMessage() else { return }
        sending = true; error = nil
        let captured = clean
        Task { @MainActor in
            defer { sending = false }
            do { try await services.sendMessage(id: messageID, text: captured); finished = true; storage.clear(); dismiss() }
            catch { self.error = "No se pudo confirmar el envío. Podés reintentar sin duplicar el mismo mensaje." }
        }
    }
}

/// Apple presents its own calendar editor. The app neither reads the agenda nor
/// requests calendar access; saving happens only when the user confirms there.
struct CalendarEventEditor: UIViewControllerRepresentable {
    let title: String
    let date: Date
    let recursYearly: Bool
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }
    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let controller = EKEventEditViewController()
        controller.eventStore = store
        let event = EKEvent(eventStore: store)
        event.title = title
        event.isAllDay = true
        event.startDate = Calendar.current.startOfDay(for: date)
        event.endDate = Calendar.current.date(byAdding: .day, value: 1, to: event.startDate)
        if recursYearly { event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)) }
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}
    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let dismiss: () -> Void
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) { dismiss() }
    }
}
