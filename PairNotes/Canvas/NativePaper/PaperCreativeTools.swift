import SwiftUI
import UIKit
import PhotosUI
import PairNotesCore

// These tools work from the actual exported pixels, independently of viewport zoom.
enum PaperPixelSampler {
    static func color(_ image: CGImage, at point: CGPoint) -> UIColor? {
        let x = min(image.width - 1, max(0, Int(point.x * CGFloat(image.width))))
        let y = min(image.height - 1, max(0, Int(point.y * CGFloat(image.height))))
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        return rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let alpha = CGFloat(bytes[3])
            guard alpha > 0 else { return nil }
            return UIColor(red: CGFloat(bytes[0]) / alpha, green: CGFloat(bytes[1]) / alpha,
                           blue: CGFloat(bytes[2]) / alpha, alpha: 1)
        }
    }

    static func contentBounds(_ image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            var minX = w, minY = h, maxX = -1, maxY = -1
            for y in 0..<h { for x in 0..<w where bytes[(y * w + x) * 4 + 3] > 12 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            } }
            guard maxX >= minX, maxY >= minY else { return nil }
            return CGRect(x: CGFloat(minX) / CGFloat(w), y: CGFloat(minY) / CGFloat(h),
                          width: CGFloat(maxX - minX + 1) / CGFloat(w), height: CGFloat(maxY - minY + 1) / CGFloat(h))
        }
    }
}

enum PaperAlignment: String, CaseIterable {
    case left = "Izquierda", center = "Centrar horizontalmente", right = "Derecha"
    case top = "Arriba", middle = "Centrar verticalmente", bottom = "Abajo", both = "Centro de la hoja"
}

enum PaperTemplate: String, CaseIterable {
    case postcard = "Postal", polaroids = "Dos Polaroids", journal = "Página de diario", letter = "Papel de carta"
    func draw(in context: CGContext, bounds: CGRect, ink: UIColor) {
        context.setStrokeColor(ink.withAlphaComponent(0.2).cgColor)
        context.setLineWidth(3)
        switch self {
        case .polaroids:
            for x: CGFloat in [100, 810] {
                let frame = CGRect(x: x, y: 200, width: 625, height: 830)
                context.setFillColor(UIColor.white.cgColor); context.fill(frame); context.stroke(frame)
                context.setFillColor(UIColor.systemPink.withAlphaComponent(0.16).cgColor)
                context.fill(CGRect(x: x + 185, y: 170, width: 240, height: 70))
            }
        case .journal:
            context.move(to: CGPoint(x: 180, y: 80)); context.addLine(to: CGPoint(x: 180, y: 1456))
            context.strokePath()
            fallthrough
        case .letter:
            for y: CGFloat in stride(from: 240, through: 1390, by: 110) {
                context.move(to: CGPoint(x: 90, y: y)); context.addLine(to: CGPoint(x: 1446, y: y))
            }
            context.strokePath()
        case .postcard: break
        }
    }
}

struct PaperEyedropper: View {
    let image: UIImage
    let onSelect: (UIColor) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UIColor?
    @State private var location: CGPoint?
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Tocá o arrastrá sobre un color de tu hoja.")
                    .font(.callout).foregroundStyle(.secondary)
                GeometryReader { geometry in
                    Image(uiImage: image).resizable().scaledToFit()
                        .overlay(alignment: .topLeading) {
                            if let location, let selected {
                                Circle().fill(Color(uiColor: selected)).frame(width: 30, height: 30)
                                    .overlay(Circle().stroke(.white, lineWidth: 3)).shadow(radius: 3)
                                    .offset(x: location.x - 15, y: location.y - 15).allowsHitTesting(false)
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            let side = geometry.size.width
                            let point = CGPoint(x: min(side, max(0, value.location.x)), y: min(side, max(0, value.location.y)))
                            if let cg = image.cgImage {
                                selected = PaperPixelSampler.color(cg, at: CGPoint(x: point.x / side, y: point.y / side))
                                location = point
                            }
                        })
                }.aspectRatio(1, contentMode: .fit)
                if let selected {
                    ColorPicker("Color elegido", selection: Binding(get: { Color(uiColor: selected) }, set: { self.selected = UIColor($0) }), supportsOpacity: false)
                }
                Spacer(minLength: 0)
            }.padding()
                .navigationTitle("Cuentagotas").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Usar color") { if let selected { onSelect(selected); dismiss() } }.disabled(selected == nil)
                    }
                }
        }
    }
}

struct PersonalStickerLibrary: View {
    let store: DraftCatalogStore
    let onInsert: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var stickers: [(id: String, image: UIImage)] = []
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var crop: SelectedPhotoCrop?
    @State private var prepared: UIImage?
    @State private var circle = false
    @State private var busy = false
    @State private var error: String?
    @State private var deleted: (id: String, image: UIImage)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let prepared {
                        Image(uiImage: cutout(prepared)).resizable().scaledToFit().frame(height: 180)
                        Toggle("Recorte circular", isOn: $circle)
                        Button("Guardar e insertar", systemImage: "plus.circle.fill") {
                            let image = cutout(prepared)
                            busy = true
                            Task { @MainActor in
                                defer { busy = false }
                                do {
                                    guard let png = image.pngData() else { throw LocalStoreError.corruptData }
                                    _ = try await store.saveSticker(png)
                                    onInsert(image); dismiss()
                                } catch { self.error = "No se pudo guardar el sticker. La biblioteca admite hasta 100 recortes." }
                            }
                        }.buttonStyle(.borderedProminent)
                        Button("Cancelar recorte") { self.prepared = nil }
                    } else {
                        if stickers.isEmpty {
                            ContentUnavailableView("Tus propios stickers", systemImage: "face.smiling",
                                description: Text("Guardá recortes para volver a usarlos en dibujos, cartas y páginas del álbum."))
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88))], spacing: 16) {
                            ForEach(stickers, id: \.id) { sticker in
                                Button { onInsert(sticker.image); dismiss() } label: {
                                    Image(uiImage: sticker.image).resizable().scaledToFit().frame(height: 88)
                                        .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                                }.buttonStyle(.plain).accessibilityLabel("Insertar sticker")
                                    .contextMenu {
                                        Button("Eliminar de mis stickers", systemImage: "trash", role: .destructive) {
                                            busy = true
                                            Task { @MainActor in
                                                defer { busy = false }
                                                do { try await store.removeSticker(sticker.id); deleted = sticker; await reload() }
                                                catch { self.error = "No se pudo eliminar. Reintentá." }
                                            }
                                        }
                                    } preview: { Image(uiImage: sticker.image).resizable().scaledToFit().frame(width: 240, height: 240) }
                            }
                        }
                        PhotosPicker(selection: $selectedPhoto, matching: .images) { Label("Crear desde una foto", systemImage: "photo.badge.plus") }
                            .buttonStyle(.bordered)
                        Text("Se guardan en este iPhone, separados por cuenta. Mantené apretado un sticker para eliminarlo.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let deleted {
                        Button("Deshacer eliminación") {
                            busy = true
                            Task { @MainActor in
                                defer { busy = false }
                                do {
                                    guard let png = deleted.image.pngData() else { throw LocalStoreError.corruptData }
                                    _ = try await store.saveSticker(png); self.deleted = nil; await reload()
                                } catch { self.error = "No se pudo recuperar el sticker. Reintentá." }
                            }
                        }
                    }
                    if busy { ProgressView("Preparando…") }
                    if let error { Text(error).font(.callout).foregroundStyle(.red) }
                }.padding()
            }.disabled(busy)
                .navigationTitle("Mis stickers").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() }.disabled(busy) } }
                .interactiveDismissDisabled(busy)
                .task { await reload() }
                .task(id: selectedPhoto) {
                    guard let item = selectedPhoto else { return }
                    busy = true
                    defer { busy = false }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self), !Task.isCancelled,
                              let image = UIImage(data: try SelectedPhoto.jpeg(data)) else { return }
                        crop = SelectedPhotoCrop(image: image)
                    } catch { self.error = "No se pudo abrir la foto." }
                }
                .fullScreenCover(item: $crop) { item in
                    PhotoCropEditor(image: item.image, onCancel: { crop = nil; selectedPhoto = nil }, onConfirm: {
                        prepared = $0; crop = nil; selectedPhoto = nil
                    })
                }
        }
    }

    private func reload() async {
        do {
            var values: [(id: String, image: UIImage)] = []
            for id in try await store.stickerIDs() {
                if let bytes = try? await store.sticker(id), let image = UIImage(data: bytes) { values.append((id, image)) }
            }
            stickers = values
        } catch { self.error = "No se pudo abrir tu biblioteca. Reintentá." }
    }
    private func cutout(_ image: UIImage) -> UIImage {
        let scale = min(1, 768 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            if circle { UIBezierPath(ovalIn: rect).addClip() }
            image.draw(in: rect)
        }
    }
}
