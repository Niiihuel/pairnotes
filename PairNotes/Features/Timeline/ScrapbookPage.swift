import PairNotesCore
import SwiftUI

struct ScrapbookPage: View {
    @ObservedObject var services: AppServices
    let memory: SharedMemory
    var compact = false
    private var decoration: MemoryDecoration { memory.decoration ?? MemoryDecoration() }
    private var theme: CoupleTheme { services.personalization.theme }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if decoration.layout == .journal { caption }
            if memory.photo != nil {
                MemoryPhotoView(services: services, memory: memory, allowsExpansion: !compact)
                    .frame(height: compact ? 155 : 280)
                    .clipShape(RoundedRectangle(cornerRadius: decoration.layout == .polaroid ? 2 : 14))
                    .padding(decoration.layout == .polaroid ? 10 : 0)
                    .padding(.bottom, decoration.layout == .polaroid ? 14 : 0)
                    .background(decoration.layout == .polaroid ? Color.white : .clear)
                    .rotationEffect(.degrees(decoration.layout == .polaroid ? -1.5 : 0))
                    .overlay(alignment: .top) {
                        if decoration.layout == .polaroid {
                            Rectangle().fill(theme.accent.opacity(0.25)).frame(width: 70, height: 20)
                                .rotationEffect(.degrees(-4)).offset(y: -7).accessibilityHidden(true)
                        }
                    }
            } else if let noteID = memory.noteId {
                MemoryLinkedDrawing(services: services, noteID: noteID).frame(height: compact ? 155 : 280)
            }
            if decoration.layout != .journal { caption }
            if !memory.body.isEmpty {
                Text(memory.body).font(.system(.body, design: .serif)).lineSpacing(5)
                    .lineLimit(compact ? 3 : nil).privacySensitive()
            }
            HStack {
                if memory.recursYearly { Label("Cada año", systemImage: "arrow.trianglehead.2.clockwise.rotate.90").font(.caption) }
                if memory.noteId != nil { Label("Con un dibujo", systemImage: "paintpalette").font(.caption) }
                Spacer(minLength: 0)
                Text(decoration.sticker.symbol).font(.system(size: compact ? 26 : 36)).accessibilityHidden(true)
            }.foregroundStyle(theme.accent)
        }
        .padding(compact ? 18 : 24).frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(theme.ink)
        .background(theme.paper, in: RoundedRectangle(cornerRadius: decoration.layout == .postcard ? 8 : 22))
        .overlay(RoundedRectangle(cornerRadius: decoration.layout == .postcard ? 8 : 22)
            .strokeBorder(theme.accent.opacity(0.13), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
    private var caption: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(memory.title).font(.system(compact ? .title3 : .title, design: .serif).weight(.medium))
            Text(memory.date.date(in: .current)?.formatted(date: .abbreviated, time: .omitted) ?? memory.date.rawValue)
                .font(.system(.callout, design: .serif)).italic().foregroundStyle(theme.accent)
        }
    }
}

private struct MemoryLinkedDrawing: View {
    @ObservedObject var services: AppServices
    let noteID: String
    @State private var note: RemoteNote?
    @State private var loadedKey: String?
    @State private var failed = false
    private var key: String { services.privateImageKey("linked-drawing:" + noteID) }
    var body: some View {
        Group {
            if loadedKey == key, let note { AsyncNoteImage(path: note.assets.widget, services: services) }
            else if failed { Label("Dibujo guardado", systemImage: "paintpalette").foregroundStyle(.secondary) }
            else { ProgressView("Cargando dibujo…") }
        }.task(id: key) {
            let captured = key; failed = false; note = nil; loadedKey = nil
            do {
                let fetched = try await services.note(id: noteID)
                guard !Task.isCancelled, captured == key else { return }
                note = fetched; loadedKey = captured
            } catch { if !Task.isCancelled, captured == key { failed = true } }
        }
    }
}
