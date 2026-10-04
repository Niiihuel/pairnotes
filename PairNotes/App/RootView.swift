import SwiftUI

private enum AppTab: Hashable {
    case home
    case create
    case memories
    case couple
}

struct RootView: View {
    @StateObject private var model = AppModel()
    @State private var selectedTab: AppTab = .home

    var body: some View {
        VStack(spacing: 0) {
            Label("Demostración · datos ficticios", systemImage: "testtube.2")
                .font(.caption)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.yellow.opacity(0.15))

            TabView(selection: $selectedTab) {
                NavigationStack {
                    HomeView(notes: model.notes) {
                        selectedTab = .create
                    }
                }
                .tabItem { Label("Inicio", systemImage: "house") }
                .tag(AppTab.home)

                NavigationStack {
                    NativePaperProbeView()
                        .navigationTitle("Crear")
                }
                .tabItem { Label("Crear", systemImage: "pencil.tip.crop.circle") }
                .tag(AppTab.create)

                NavigationStack {
                    TimelineView(notes: model.notes)
                }
                .tabItem { Label("Recuerdos", systemImage: "rectangle.stack") }
                .tag(AppTab.memories)

                NavigationStack {
                    CoupleView(profile: model.profile)
                }
                .tabItem { Label("Nosotros", systemImage: "person.2") }
                .tag(AppTab.couple)
            }
        }
        .task { await model.load() }
        .onOpenURL { url in
            guard url.scheme == "pairnotes", url.host == "create" else { return }
            selectedTab = .create
        }
    }
}
