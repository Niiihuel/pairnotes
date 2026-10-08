import PairNotesCore
import SwiftUI

struct PersonalizationView: View {
    @ObservedObject var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var value: CouplePersonalization
    @State private var saving = false
    @State private var error: String?
    private let scope: String
    private let storage: MemoryCompositionStorage
    @State private var finished = false

    init(services: AppServices) {
        self.services = services
        let storage = MemoryCompositionStorage(key: services.privateImageKey("personalization-draft"))
        self.storage = storage
        _value = State(initialValue: storage.loadValue() ?? services.personalization)
        scope = services.privateImageKey("personalization")
    }
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(value.phrase.isEmpty ? "Vista previa" : value.phrase)
                        .font(.system(.title2, design: .serif).weight(.medium))
                    HStack {
                        ForEach(services.coupleSpace?.profiles ?? []) { profile in
                            Text(value.name(for: profile.uid, fallback: profile.displayName)).font(.subheadline.bold())
                            if profile.id == services.coupleSpace?.profiles.first?.id { Text("♡") }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .foregroundStyle(value.theme.ink)
            }.listRowBackground(value.theme.paper)
            Section("Tema") {
                Picker("Color", selection: $value.theme) {
                    ForEach(CoupleTheme.allCases, id: \.self) { theme in Text(theme.title).tag(theme) }
                }
            }
            Section("Frase y apodos") {
                TextField("Frase opcional", text: $value.phrase, axis: .vertical).lineLimit(2...4)
                ForEach(services.coupleSpace?.profiles ?? []) { profile in
                    TextField("Apodo de \(profile.displayName)", text: Binding(
                        get: { value.nicknames[profile.uid] ?? "" },
                        set: { value.nicknames[profile.uid] = $0 }))
                }
            }
            Section {
                Picker("Foto de portada", selection: Binding(get: { value.coverMemoryId ?? "" },
                    set: { value.coverMemoryId = $0.isEmpty ? nil : $0 })) {
                    Text("Sin portada").tag("")
                    if let coverID = value.coverMemoryId,
                       services.coupleSpace?.memories.contains(where: { $0.id == coverID && $0.photo != nil }) != true {
                        Text("Foto ya no disponible · elegí otra").tag(coverID)
                    }
                    ForEach((services.coupleSpace?.memories ?? []).filter { $0.photo != nil }) { memory in
                        Text(memory.title).tag(memory.id)
                    }
                }
                if let memory = services.coupleSpace?.memories.first(where: { $0.id == value.coverMemoryId && $0.photo != nil }) {
                    MemoryPhotoView(services: services, memory: memory).frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            } header: { Text("Portada del álbum") }
            Section {
                ForEach(value.homeOrder, id: \.self) { section in
                    Label(section.title, systemImage: "line.3.horizontal")
                }.onMove { indices, destination in value.homeOrder.move(fromOffsets: indices, toOffset: destination) }
            } header: { Text("Orden de Inicio") } footer: { Text("Arrastrá las secciones para elegir qué ver primero.") }
            .environment(\.editMode, .constant(.active))
            if value.revision != services.personalization.revision {
                Section {
                    Text("Tu pareja actualizó la personalización. Cargá sus cambios antes de guardar.")
                    Button("Cargar cambios compartidos") { value = services.personalization; storage.clear(); error = nil }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            if saving { ProgressView("Guardando para los dos…") }
        }
        .tint(value.theme.accent)
        .disabled(saving)
        .navigationTitle("Apariencia").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Guardar") { save() }
                    .disabled(saving || value == services.personalization || value.revision != services.personalization.revision ||
                        value.phrase.utf16.count > 160 || value.nicknames.values.contains { $0.utf16.count > 40 })
            }
        }
        .onChange(of: value) { _, value in
            guard !finished else { return }
            do { try storage.saveValue(value) }
            catch { self.error = "No se pudo conservar este borrador en el iPhone." }
        }
        .onChange(of: services.privateImageKey("personalization")) { _, key in if key != scope { dismiss() } }
    }
    private func save() {
        guard !saving, services.privateImageKey("personalization") == scope else { return }
        saving = true; error = nil
        let captured = value
        Task { @MainActor in
            defer { saving = false }
            do { try await services.updatePersonalization(captured); finished = true; storage.clear(); dismiss() }
            catch {
                self.error = "No se pudo guardar. Tus cambios siguen acá; revisá la conexión o los cambios de tu pareja."
                try? await services.refreshCoupleSpace()
            }
        }
    }
}
