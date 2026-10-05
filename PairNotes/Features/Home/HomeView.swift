import PairNotesCore
import SwiftUI

struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var services: AppServices
    let createNote: () -> Void
    let openNote: (RemoteNote) -> Void
    @State private var destination: Destination?
    private enum Destination: String, Identifiable {
        case message, date, distance
        var id: String { rawValue }
    }

    init(model: AppModel, createNote: @escaping () -> Void, openNote: @escaping (RemoteNote) -> Void) {
        self.model = model
        self.services = model.services
        self.createNote = createNote
        self.openNote = openNote
    }

    private var theme: CoupleTheme { services.personalization.theme }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let cover = services.coupleSpace?.memories.first(where: { $0.id == services.personalization.coverMemoryId && $0.photo != nil }) {
                    MemoryPhotoView(services: services, memory: cover, allowsExpansion: true).frame(height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 28))
                        .overlay(alignment: .bottomLeading) {
                            Text("NOSOTROS ♡").font(.caption.bold()).tracking(3).padding(16)
                                .foregroundStyle(.white).shadow(radius: 4)
                        }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(services.membership == nil ? "Algo lindo empieza acá" : "Su pequeño mundo")
                        .font(.largeTitle.bold()).tracking(-1)
                    Text(services.membership == nil ? "Dibujos, palabras y momentos para compartir." : (services.personalization.phrase.isEmpty ? "Un lugar para sentirse cerca, todos los días." : services.personalization.phrase))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Button(action: createNote) {
                    HStack(spacing: 16) {
                        Image(systemName: "pencil.tip.crop.circle.fill").font(.largeTitle)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Un dibujo puede decir mucho").font(.headline)
                            Text("Creá algo para esa persona especial").font(.caption)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                    }.foregroundStyle(.white).padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [theme == .night ? Color(rgb: 0x73558A) : theme.accent, Color(rgb: 0x482C4F)],
                            startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 26))
                }.buttonStyle(.plain).accessibilityLabel("Crear un dibujo")

                if services.membership != nil {
                    ThinkingOfYouCard(services: services)
                    NavigationLink {
                        LettersView(services: services, notes: model.notes, catalog: model.catalog)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "envelope.badge.shield.half.filled").font(.title)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Cartitas para después").font(.headline)
                                Text("Palabras que esperan su momento").font(.caption)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.padding(20).background(theme.paper, in: RoundedRectangle(cornerRadius: 24))
                    }.buttonStyle(.plain)
                }
                ForEach(services.personalization.homeOrder, id: \.self) { section in
                    homeSection(section)
                }
                if let status = model.status ?? services.spaceError {
                    Label(status, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                }
                Text("Hecho de pequeños detalles, pensado para los dos.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 8)
            }.padding(20)
        }
        .foregroundStyle(theme.ink)
        .background(theme.canvas)
        .navigationTitle("Inicio").navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.foreground() }
        .sheet(item: $destination) { destination in
            switch destination {
            case .message: MessageComposer(services: services)
            case .date: TogetherDateEditor(services: services)
            case .distance: NavigationStack { DistanceSettingsView(services: services) }
            }
        }
        .onChange(of: services.identity?.uid) { _, _ in destination = nil }
        .onChange(of: services.membership?.id) { _, _ in destination = nil }
    }

    @ViewBuilder
    private func homeSection(_ section: HomeSection) -> some View {
        switch section {
        case .story:
                if services.membership != nil {
                    card {
                        CouplePortraits(services: services)
                        Divider().padding(.vertical, 4)
                        Button { destination = .date } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("NUESTRA HISTORIA").font(.caption2.weight(.bold)).tracking(1.5)
                                    if let started = services.coupleSpace?.startedOn,
                                       let days = started.daysTogether(on: Date(), calendar: .current) {
                                        Text("\(days) días juntos").font(.title2.bold())
                                        Text("Desde \(started.date(in: .current)?.formatted(date: .long, time: .omitted) ?? started.rawValue)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else { Text("Elegí su primera fecha").font(.headline) }
                                }
                                Spacer()
                                Image(systemName: "heart.circle.fill").font(.largeTitle).foregroundStyle(theme.accent)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
        case .message:
                if services.membership != nil {
                    sectionTitle("Palabras que abrazan", subtitle: "El último mensaje que te dejó")
                    card {
                        if let message = services.coupleSpace?.latestMessage {
                            HStack(alignment: .top, spacing: 12) {
                                ProfileAvatarView(services: services, uid: message.authorID,
                                    name: services.partnerNickname,
                                    reference: services.coupleSpace?.profiles.first(where: { $0.uid == message.authorID })?.avatar, size: 40)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(message.text).font(.title3).fixedSize(horizontal: false, vertical: true).privacySensitive()
                                    Text(message.sentAt, format: .dateTime.day().month().hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } else { Text("A veces, un «te pienso» cambia todo el día.").foregroundStyle(.secondary) }
                        Button("Escribir un mensaje", systemImage: "bubble.left.and.text.bubble.right") { destination = .message }
                            .font(.subheadline.weight(.semibold)).padding(.top, 6)
                    }
                }
        case .drawing:
                sectionTitle("Para guardar cerquita", subtitle: "El último dibujo recibido")
                card {
                    if let note = model.latestReceived {
                        Button { openNote(note) } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                AsyncNoteImage(path: note.assets.widget, services: services)
                                    .aspectRatio(1, contentMode: .fit).frame(maxHeight: 360)
                                    .clipShape(RoundedRectangle(cornerRadius: 18))
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("De \(services.partnerNickname)").font(.headline)
                                        Text(note.serverPublishedAt, format: .dateTime.day().month().hour().minute())
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.right.circle").font(.title2).foregroundStyle(theme.accent)
                                }
                            }
                        }.buttonStyle(.plain).accessibilityLabel("Abrir el último dibujo recibido")
                    } else if model.isLoading { ProgressView("Buscando recuerdos…") }
                    else {
                        Image(systemName: "heart.text.square").font(.largeTitle).foregroundStyle(theme.accent)
                        Text("Un espacio para su próximo dibujo").font(.headline)
                        Text(services.membership == nil ? "Vinculá sus cuentas en Nosotros para empezar a compartir." : "Cuando tu pareja te envíe algo, lo vas a encontrar acá.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
        case .distance:
                if services.membership != nil {
                    card {
                        Button { destination = .distance } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "location.circle.fill").font(.largeTitle).foregroundStyle(theme.accent)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Entre ustedes").font(.headline)
                                    DistanceSummary(distance: services.coupleSpace?.location.distance).font(.subheadline)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
        }
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.bold())
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 24))
    }
}
