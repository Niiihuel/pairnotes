import PairNotesCore
import SwiftUI

struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var services: AppServices
    let createNote: () -> Void
    let openNote: (RemoteNote) -> Void
    let createPhoto: () -> Void
    let openPhoto: (String) -> Void
    let openMessages: () -> Void
    let editDate: () -> Void
    let openDistance: () -> Void

    init(model: AppModel, createNote: @escaping () -> Void, openNote: @escaping (RemoteNote) -> Void,
         createPhoto: @escaping () -> Void = {}, openPhoto: @escaping (String) -> Void = { _ in },
         openMessages: @escaping () -> Void = {}, editDate: @escaping () -> Void = {}, openDistance: @escaping () -> Void = {}) {
        self.model = model
        self.services = model.services
        self.createNote = createNote
        self.openNote = openNote
        self.createPhoto = createPhoto; self.openPhoto = openPhoto
        self.openMessages = openMessages; self.editDate = editDate; self.openDistance = openDistance
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
                    Text(services.membership == nil ? "Para compartir" : "Vos y \(services.partnerNickname)")
                        .font(.largeTitle.bold())
                    if !services.personalization.phrase.isEmpty {
                        Text(services.personalization.phrase).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { quickActions }
                    VStack(spacing: 12) { quickActions }
                }

                if services.membership != nil {
                    if let photo = services.coupleSpace?.latestPhoto {
                        Button { openPhoto(photo.id) } label: {
                            CouplePhotoCard(services: services, photo: photo)
                        }.buttonStyle(.plain)
                    }
                    ThinkingOfYouCard(services: services)
                }
                ForEach(services.personalization.homeOrder, id: \.self) { section in
                    homeSection(section)
                }
                if let status = model.status ?? services.spaceError {
                    Label(status, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
        .foregroundStyle(theme.ink)
        .background(theme.canvas)
        .navigationTitle("Inicio").navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.foreground() }
    }

    @ViewBuilder
    private var quickActions: some View {
        Button(action: createNote) {
            Label("Dibujar", systemImage: "pencil.tip.crop.circle")
                .font(.headline).fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.borderedProminent).accessibilityLabel("Crear un dibujo")
        if services.membership != nil {
            Button(action: createPhoto) {
                Label("Enviar foto", systemImage: "camera")
                    .font(.headline).fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func homeSection(_ section: HomeSection) -> some View {
        switch section {
        case .story:
                if services.membership != nil {
                    card {
                        CouplePortraits(services: services)
                        Divider()
                        Button(action: editDate) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let started = services.coupleSpace?.startedOn,
                                       let days = started.daysTogether(on: Date(), calendar: .current) {
                                        Text("\(days) días juntos").font(.title2.bold())
                                        Text("Desde \(started.date(in: .current)?.formatted(date: .long, time: .omitted) ?? started.rawValue)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else { Text("Nuestra fecha").font(.headline) }
                                }
                                Spacer()
                                Image(systemName: "heart.circle.fill").font(.largeTitle).foregroundStyle(theme.accent)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
        case .message:
                if services.membership != nil {
                    sectionTitle("Último mensaje")
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
                        } else { Text("Sin mensajes recibidos").foregroundStyle(.secondary) }
                        Button("Ver mensajes", systemImage: "bubble.left.and.text.bubble.right", action: openMessages)
                            .font(.subheadline.weight(.semibold)).padding(.top, 6)
                    }
                }
        case .drawing:
                sectionTitle("Último dibujo")
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
                    } else if model.isLoading { ProgressView().accessibilityLabel("Buscando dibujos") }
                    else {
                        Image(systemName: "heart.text.square").font(.largeTitle).foregroundStyle(theme.accent)
                        Text("Sin dibujos recibidos").foregroundStyle(.secondary)
                    }
                }
        case .distance:
                if services.membership != nil {
                    card {
                        Button(action: openDistance) {
                            HStack(spacing: 14) {
                                Image(systemName: "location.circle.fill").font(.largeTitle).foregroundStyle(theme.accent)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Distancia").font(.headline)
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

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.title3.bold())
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 24))
    }
}
