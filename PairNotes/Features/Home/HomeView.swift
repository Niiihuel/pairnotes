import PairNotesCore
import SwiftUI

struct HomeView: View {
    let notes: [DemoNote]
    let createNote: () -> Void

    var body: some View {
        List {
            Section("Una nota de ejemplo") {
                if let note = notes.max(by: { $0.createdAt < $1.createdAt }) {
                    NavigationLink {
                        DemoNoteDetailView(note: note)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(note.title).font(.headline)
                            Text(note.message)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                            Text("De \(note.author.displayName) · perfil ficticio")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    Text("No hay notas de ejemplo disponibles.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(action: createNote) {
                    Label("Crear una prueba local", systemImage: "square.and.pencil")
                }
            } footer: {
                Text("Los ejemplos son ficticios. Todavía no hay una cuenta ni envíos entre personas.")
            }

            Section("Distancia") {
                Label("Ubicación sin activar", systemImage: "location.slash")
                Text("Compartir ubicación será opcional. Esta versión no solicita permisos ni obtiene posiciones.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("PairNotes")
    }
}
