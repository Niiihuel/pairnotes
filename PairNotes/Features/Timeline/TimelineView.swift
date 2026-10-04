import PairNotesCore
import SwiftUI

struct TimelineView: View {
    let notes: [DemoNote]

    var body: some View {
        List {
            Section {
                ForEach(notes.sorted(by: { $0.createdAt > $1.createdAt }), id: \.id) { note in
                    NavigationLink {
                        DemoNoteDetailView(note: note)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.title).font(.headline)
                            Text(note.author.displayName)
                                .foregroundStyle(.secondary)
                            Text(note.createdAt, format: .dateTime.day().month().year())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Recuerdos de demostración. Los borradores del editor permanecen en este dispositivo y no aparecen como notas enviadas.")
            }
        }
        .navigationTitle("Recuerdos")
    }
}

struct DemoNoteDetailView: View {
    let note: DemoNote

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Nota ficticia de demostración", systemImage: "testtube.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(note.title).font(.title2.bold())
                Text(note.message).font(.body)
                    .textSelection(.enabled)

                Divider()
                Text("\(note.author.displayName) · perfil ficticio")
                    .font(.subheadline)
                Text(note.createdAt, format: .dateTime.day().month().year())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Ejemplo")
        .navigationBarTitleDisplayMode(.inline)
    }
}
