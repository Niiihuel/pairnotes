import PairNotesCore
import SwiftUI

struct ChatLetterCard: View {
    @ObservedObject var services: AppServices
    let letter: TimeCapsuleLetter
    let onOpen: () -> Void

    private var canRead: Bool { letter.authorId == services.identity?.uid || letter.canOpen }
    private var audioOnly: Bool {
        canRead && letter.audio != nil && letter.photo == nil && letter.drawing == nil && letter.noteId == nil &&
        (letter.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
    private var belongsToCurrentCouple: Bool {
        guard services.membershipResolved, let uid = services.identity?.uid, let pair = services.membership else { return false }
        return (try? letter.validate(uid: uid, memberIDs: pair.memberIDs)) != nil
    }

    var body: some View {
        Group {
            if belongsToCurrentCouple {
                if audioOnly {
                    LetterVoicePlayer(services: services, letter: letter)
                } else {
                    Button(action: onOpen) {
                        LetterEnvelopePaper(opened: canRead && letter.openedAt != nil) {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(canRead ? letter.title ?? "Carta" : "Carta cerrada",
                                      systemImage: canRead ? "envelope.open" : "lock")
                                    .font(.system(.headline, design: .serif))
                                if canRead {
                                    Text(letter.authorId == services.identity?.uid ? "Leer carta" : "Abrir carta")
                                        .font(.subheadline)
                                } else {
                                    Text(letter.opensAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canRead)
                }
            }
        }.privacySensitive()
    }
}

struct ChatPhotoCard: View {
    @ObservedObject var services: AppServices
    let photo: CouplePhoto
    let onOpen: () -> Void

    var body: some View {
        if services.membershipResolved, let uid = services.identity?.uid, let pair = services.membership,
           pair.memberIDs.contains(uid),
           (try? photo.validate(memberIDs: pair.memberIDs)) != nil {
            Button(action: onOpen) { CouplePhotoCard(services: services, photo: photo) }
                .buttonStyle(.plain)
                .accessibilityHint("Abrir foto y reacciones")
        }
    }
}

struct ChatDrawingCard: View {
    @ObservedObject var services: AppServices
    let note: RemoteNote
    let onOpen: () -> Void

    private var belongsToCurrentCouple: Bool {
        guard services.membershipResolved, let uid = services.identity?.uid, let pair = services.membership else { return false }
        return note.pairID == pair.id && note.pairEpoch == pair.pairEpoch && pair.memberIDs.contains(uid) &&
            Set([note.authorID, note.recipientID]) == Set(pair.memberIDs)
    }

    var body: some View {
        if belongsToCurrentCouple {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 10) {
                    AsyncNoteImage(path: note.assets.thumbnail, services: services)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    Label(note.authorID == services.identity?.uid ? "Tu dibujo" : "Dibujo de \(services.partnerNickname)",
                          systemImage: "pencil.tip.crop.circle")
                        .font(.subheadline.weight(.medium))
                }
                .padding(12)
                .background(services.personalization.theme.card, in: RoundedRectangle(cornerRadius: 22))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Abrir dibujo y respuesta")
            .privacySensitive()
        }
    }
}
