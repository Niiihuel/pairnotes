import SwiftUI

/// Warm stationery inspired by the paper, margin and wax seal in para-vos.
/// Text uses scalable system serif styles; decoration never receives input.
struct LetterStationeryPalette {
    let dark: Bool
    var canvas: Color { dark ? rgb(0x211C1B) : rgb(0xF3EBE1) }
    var paper: Color { dark ? rgb(0x322A28) : rgb(0xFFFAF1) }
    var ink: Color { dark ? rgb(0xF7EEE3) : rgb(0x48362F) }
    var secondaryInk: Color { dark ? rgb(0xD4C1B6) : rgb(0x70574D) }
    var accent: Color { dark ? rgb(0xE5ACB9) : rgb(0x83394A) }
    var envelope: Color { dark ? rgb(0x493338) : rgb(0xEED6D1) }
    var fold: Color { dark ? rgb(0xB9818D) : rgb(0xB57680) }
    private func rgb(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 255) / 255,
              green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

struct LetterPaper<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = 36
    let ruled: Bool
    let content: Content

    init(ruled: Bool = true, @ViewBuilder content: () -> Content) {
        self.ruled = ruled; self.content = content()
    }

    var body: some View {
        let palette = LetterStationeryPalette(dark: scheme == .dark)
        content
            .padding(.leading, 42).padding(.trailing, 24).padding(.vertical, 30)
            .frame(maxWidth: .infinity, minHeight: 340, alignment: .topLeading)
            .foregroundStyle(palette.ink)
            .background {
                ZStack(alignment: .top) {
                    palette.paper
                    LetterRuling(spacing: max(28, lineHeight), ruled: ruled)
                        .stroke(palette.fold.opacity(contrast == .increased ? 0.25 : 0.16), lineWidth: 0.75)
                    Rectangle().fill(palette.accent).frame(height: 3)
                    GeometryReader { geometry in
                        ForEach([CGFloat(90), max(140, min(340, geometry.size.height - 50))], id: \.self) { y in
                            Circle().fill(palette.canvas).frame(width: 10, height: 10)
                                .overlay { Circle().strokeBorder(palette.fold.opacity(0.25), lineWidth: 0.5) }
                                .position(x: 12, y: y)
                        }
                    }
                }
                .allowsHitTesting(false).accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(palette.fold.opacity(0.25), lineWidth: 0.75).allowsHitTesting(false) }
            .shadow(color: .black.opacity(scheme == .dark ? 0.18 : 0.07), radius: 12, y: 5)
    }
}

private struct LetterRuling: Shape {
    let spacing: CGFloat
    let ruled: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 28, y: 0)); path.addLine(to: CGPoint(x: 28, y: rect.height))
        guard ruled else { return path }
        var y: CGFloat = 72
        while y < rect.height {
            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: rect.width, y: y))
            y += spacing
        }
        return path
    }
}

struct LetterEnvelopePaper<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let opened: Bool
    let content: Content
    init(opened: Bool = false, @ViewBuilder content: () -> Content) {
        self.opened = opened; self.content = content()
    }
    var body: some View {
        let palette = LetterStationeryPalette(dark: scheme == .dark)
        content
            .padding(24).padding(.trailing, 28)
            .frame(maxWidth: .infinity, minHeight: 154, alignment: .leading)
            .foregroundStyle(palette.ink)
            .background {
                ZStack {
                    opened ? palette.paper : palette.envelope
                    EnvelopeFold().stroke(palette.fold.opacity(0.3), lineWidth: 0.8)
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: opened ? "envelope.open" : "heart.fill")
                    .font(.body.weight(.medium)).foregroundStyle(palette.accent)
                    .frame(width: 36, height: 36)
                    .background(palette.paper.opacity(0.85), in: Circle())
                    .padding(14).accessibilityHidden(true).allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.fold.opacity(0.3), lineWidth: 0.8).allowsHitTesting(false) }
            .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
    }
}

private struct EnvelopeFold: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: rect.midX, y: rect.height * 0.34))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.move(to: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width * 0.26, y: rect.height * 0.68))
        path.move(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width * 0.74, y: rect.height * 0.68))
        return path
    }
}

private struct LetterStationeryPreview: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                LetterEnvelopePaper {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("De alguien que te quiere").font(.system(.title3, design: .serif))
                        Label("Sobre cerrado", systemImage: "lock").font(.subheadline)
                        Text("12 de octubre · 18:00").font(.caption)
                    }
                }
                LetterPaper {
                    VStack(alignment: .leading, spacing: 28) {
                        Text("Para vos,").font(.system(.largeTitle, design: .serif))
                        Text("Hoy quería guardar unas palabras para cuando las necesites.\n\nIncluso en un día lleno de cosas, siempre hay un momento para pensar en nosotros.")
                            .font(.system(.body, design: .serif)).lineSpacing(8)
                        Text("Yo ♡").font(.system(.title3, design: .serif).italic())
                    }
                }
            }.padding(20)
        }
    }
}

struct LetterStationery_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            LetterStationeryPreview().preferredColorScheme(.light).previewDisplayName("Carta · claro")
            LetterStationeryPreview().preferredColorScheme(.dark).previewDisplayName("Carta · oscuro")
            LetterStationeryPreview().preferredColorScheme(.dark)
                .dynamicTypeSize(.accessibility3)
                .previewDisplayName("Carta · letra grande")
        }
    }
}
