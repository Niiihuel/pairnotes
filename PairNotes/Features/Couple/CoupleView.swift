import PairNotesCore
import SwiftUI

struct CoupleView: View {
    let profile: UserProfile?

    var body: some View {
        List {
            Section("Perfil de ejemplo") {
                if let profile {
                    Label(profile.displayName, systemImage: profile.avatarSymbol)
                    Text("Perfil ficticio. No hay sesión iniciada ni una pareja vinculada.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Cuenta y privacidad") {
                Label("Google y Apple pendientes de conectar", systemImage: "person.crop.circle")
                Label("Ubicación sin activar", systemImage: "location.slash")
                Text("Vincular una cuenta y compartir ubicación serán decisiones independientes. Podrás usar las notas sin compartir tu posición.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Widget de prueba") {
                Text("Guardá una composición desde Crear y usá su opción de widget local. Luego agregá el widget PairNotes desde la pantalla de inicio.")
                Text("La prueba requiere configurar el grupo compartido de la app y su extensión. iOS decide cuándo actualiza el widget.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Nosotros")
    }
}
