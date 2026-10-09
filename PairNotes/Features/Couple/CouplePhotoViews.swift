import PairNotesCore
import SwiftUI
import UIKit

struct CouplePhotoCard: View {
    @ObservedObject var services: AppServices
    let photo: CouplePhoto
    @State private var image: UIImage?
    @State private var loadedScope: String?
    private var scope: String { services.privateImageKey("couple-photo:\(photo.id):\(photo.photo.id)") }

    var body: some View {
        HStack(spacing: 16) {
            Group {
                if loadedScope == scope, let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Image(systemName: "photo.fill").font(.title).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
            }.frame(width: 80, height: 100).clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 6) {
                Text(photo.authorId == services.identity?.uid ? "Tu foto" : "De \(services.partnerNickname)").font(.headline)
                if !photo.caption.isEmpty { Text(photo.caption).font(.subheadline).lineLimit(3) }
                Text(photo.sentAt, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)
                if let reaction = photo.reaction { Text(reaction.kind.symbol).font(.title3) }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(services.personalization.theme.paper, in: RoundedRectangle(cornerRadius: 24))
            .privacySensitive()
            .task(id: scope) {
                let key = scope; image = nil; loadedScope = nil
                if let data = try? await services.photoImage(photo), !Task.isCancelled, scope == key {
                    image = UIImage(data: data); loadedScope = key
                }
            }
    }
}

struct CouplePhotoDetailView: View {
    let photoID: String
    @ObservedObject var services: AppServices
    let replyWithPhoto: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var photo: CouplePhoto?
    @State private var image: UIImage?
    @State private var loading = false
    @State private var reacting = false
    @State private var showingActivity = false
    @State private var error: String?
    @State private var activityMessage: String?
    @State private var requestGeneration = 0
    @State private var loadedScope: String?
    private var scope: String { services.privateImageKey("couple-photo-detail:" + photoID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if loading { ProgressView("Abriendo foto…").frame(maxWidth: .infinity) }
                if loadedScope == scope, let photo, let image {
                    Image(uiImage: image).resizable().scaledToFit().privacySensitive()
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                    HStack {
                        Text(photo.authorId == services.identity?.uid ? "Tu foto" : "De \(services.partnerNickname)").font(.headline)
                        Spacer()
                        Text(photo.sentAt, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                    if !photo.caption.isEmpty { Text(photo.caption).font(.title3).privacySensitive() }
                    if photo.recipientId == services.identity?.uid {
                        ReactionBubble(tail: .topLeading) {
                            HStack(spacing: 4) {
                                ForEach(PhotoReactionKind.allCases, id: \.self) { kind in
                                    Button { react(kind, photo: photo) } label: {
                                        ReactionEmojiLabel(symbol: kind.symbol, selected: photo.reaction?.kind == kind,
                                                           tint: services.personalization.theme.accent)
                                    }.disabled(reacting)
                                        .accessibilityLabel(kind.title)
                                        .accessibilityValue(photo.reaction?.kind == kind ? "Reacción enviada" : "")
                                        .accessibilityAddTraits(photo.reaction?.kind == kind ? .isSelected : [])
                                }
                                Button(action: replyWithPhoto) {
                                    ReactionCameraLabel(tint: services.personalization.theme.accent)
                                }.accessibilityLabel("Responder con una foto")
                            }
                            .buttonStyle(ReactionBubbleButtonStyle())
                        }.accessibilityLabel("Reaccionar a la foto")
                        if reacting { ProgressView("Enviando reacción…") }
                        Button("Mostrar en pantalla bloqueada", systemImage: "lock.rectangle") { startActivity(photo) }
                            .buttonStyle(.bordered).disabled(showingActivity)
                    } else if let reaction = photo.reaction {
                        ReactionBubble(tail: .topLeading) {
                            Label("\(services.partnerNickname) reaccionó \(reaction.kind.symbol)", systemImage: "checkmark")
                                .font(.subheadline).padding(8)
                        }
                    }
                }
                if let activityMessage { Label(activityMessage, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary) }
                if let error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    if image == nil { Button("Reintentar") { Task { await load() } }.buttonStyle(.bordered) }
                }
            }.padding(20)
        }
        .coupleScreenBackground()
        .navigationTitle("Foto").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Listo") { dismiss() } } }
        .task(id: scope) { await load() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
    }

    private func load() async {
        guard !loading, !reacting else { return }
        let key = scope; loading = true; error = nil
        let generation = requestGeneration
        defer { loading = false }
        do {
            let value = try await services.photo(id: photoID)
            let bytes = try await services.photoImage(value)
            guard !Task.isCancelled, scope == key, generation == requestGeneration, let image = UIImage(data: bytes) else { return }
            photo = value; self.image = image; loadedScope = key
        } catch { if scope == key, generation == requestGeneration, !Task.isCancelled { self.error = "No se pudo abrir esta foto. Revisá la conexión y reintentá." } }
    }

    private func react(_ kind: PhotoReactionKind, photo: CouplePhoto) {
        guard !reacting else { return }
        let key = scope; reacting = true; error = nil
        requestGeneration += 1
        Task { @MainActor in
            defer { reacting = false }
            do {
                let value = try await services.setPhotoReaction(photoID: photo.id, assetID: photo.photo.id, kind: kind)
                guard scope == key else { return }
                self.photo = value; UISelectionFeedbackGenerator().selectionChanged()
                await PairPhotoActivityController.shared.synchronize(services: services)
            } catch { if scope == key { self.error = "No se pudo enviar la reacción. Tocala para reintentar." } }
        }
    }

    private func startActivity(_ photo: CouplePhoto) {
        guard !showingActivity else { return }
        showingActivity = true; activityMessage = nil
        Task { @MainActor in
            defer { showingActivity = false }
            do { try await PairPhotoActivityController.shared.show(photo: photo, services: services); activityMessage = "Tu foto ya está en la pantalla bloqueada." }
            catch { activityMessage = error.localizedDescription }
        }
    }
}
