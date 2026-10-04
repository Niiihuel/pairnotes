import PairNotesCore
import SwiftUI

struct HomeView: View {
    @ObservedObject var model: AppModel
    let createNote: () -> Void
    let openNote: (RemoteNote) -> Void

    var body: some View {
        List {
            Section("Para vos") {
                if let note = model.latestReceived {
                    Button { openNote(note) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            AsyncNoteImage(path: note.assets.widget, services: model.services)
                                .aspectRatio(1, contentMode: .fit)
                                .frame(maxHeight: 340)
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                            Text("De \(model.membership?.partner.displayName ?? "tu pareja")")
                                .font(.headline)
                            Text(note.serverPublishedAt, format: .dateTime.day().month().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Abrir el último dibujo recibido")
                } else if model.isLoading {
                    ProgressView("Buscando recuerdos…")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "heart.text.square").font(.largeTitle).foregroundStyle(.pink)
                        Text(model.membership == nil ? "Un espacio para ustedes" : "El próximo dibujo aparece acá")
                            .font(.headline)
                        Text(model.membership == nil
                             ? "Podés empezar a dibujar ahora. Iniciá sesión y vinculá las dos cuentas desde Nosotros para compartir."
                             : "Cuando tu pareja te envíe una nota, la vas a encontrar acá y en Recuerdos.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                }
            }

            Section {
                Button(action: createNote) {
                    Label("Crear un dibujo", systemImage: "square.and.pencil")
                }
            } footer: {
                Text("Los borradores se guardan en este iPhone. Elegís cuándo enviarlos.")
            }
            if let status = model.status {
                Section {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityLabel("Estado: \(status)")
                }
            }
        }
        .navigationTitle("PairNotes")
        .refreshable { await model.foreground() }
    }
}
