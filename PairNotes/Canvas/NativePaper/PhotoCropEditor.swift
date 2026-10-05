import SwiftUI
import UIKit

/// Pixel operations used by the crop UI. Coordinates are normalized against
/// the orientation-corrected source, never against the resized preview.
@MainActor
enum PhotoCropGeometry {
    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up || image.cgImage == nil else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    static func rotated(_ image: UIImage) -> UIImage {
        let size = CGSize(width: image.size.height, height: image.size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
            context.cgContext.rotate(by: .pi / 2)
            image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2,
                                  width: image.size.width, height: image.size.height))
        }
    }

    static func cropped(_ image: UIImage, rect: CGRect) -> UIImage? {
        guard let source = image.cgImage, rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        let clean = rect.intersection(full)
        guard !clean.isNull, clean.width > 0, clean.height > 0 else { return nil }
        let pixels = CGRect(x: clean.minX * CGFloat(source.width), y: clean.minY * CGFloat(source.height),
                            width: clean.width * CGFloat(source.width), height: clean.height * CGFloat(source.height))
        guard let cropped = source.cropping(to: pixels) else { return nil }
        return UIImage(cgImage: cropped)
    }

    static func moved(_ rect: CGRect, by offset: CGSize) -> CGRect {
        CGRect(x: min(1 - rect.width, max(0, rect.minX + offset.width)),
               y: min(1 - rect.height, max(0, rect.minY + offset.height)),
               width: rect.width, height: rect.height)
    }

    static func resized(_ rect: CGRect, by offset: CGSize, topLeft: Bool) -> CGRect {
        if topLeft {
            let x = min(rect.maxX - 0.08, max(0, rect.minX + offset.width))
            let y = min(rect.maxY - 0.08, max(0, rect.minY + offset.height))
            return CGRect(x: x, y: y, width: rect.maxX - x, height: rect.maxY - y)
        }
        return CGRect(x: rect.minX, y: rect.minY,
                      width: min(1 - rect.minX, max(0.08, rect.width + offset.width)),
                      height: min(1 - rect.minY, max(0.08, rect.height + offset.height)))
    }

    static func square(for size: CGSize) -> CGRect {
        let side = min(size.width, size.height)
        let width = side / size.width, height = side / size.height
        return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }
}

/// Reusable local cropper. Cancel never imports or mutates the source. Only the
/// confirmed pixels are handed to PaperKit (or an avatar caller).
struct PhotoCropEditor: View {
    let onCancel: () -> Void
    let onConfirm: (UIImage) -> Void
    @State private var image: UIImage
    @State private var crop = PhotoCropGeometry.full
    @State private var dragStart: CGRect?
    @State private var errorMessage: String?

    init(image: UIImage, onCancel: @escaping () -> Void, onConfirm: @escaping (UIImage) -> Void) {
        _image = State(initialValue: PhotoCropGeometry.normalized(image))
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("Arrastrá el marco para moverlo y sus esquinas para recortar.")
                    .font(.subheadline).foregroundStyle(.secondary)
                GeometryReader { geometry in
                    let scale = min(geometry.size.width / image.size.width, geometry.size.height / image.size.height)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    ZStack {
                        Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                        CropShade(rect: crop).fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
                            .frame(width: size.width, height: size.height).allowsHitTesting(false)
                        cropOverlay(size: size)
                    }
                    .frame(width: size.width, height: size.height)
                    .coordinateSpace(name: "photoCropCanvas")
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                .frame(maxHeight: .infinity)
                HStack(spacing: 22) {
                    Button("Girar", systemImage: "rotate.right") {
                        image = PhotoCropGeometry.rotated(image)
                        crop = PhotoCropGeometry.full
                    }
                    Button("Cuadrado", systemImage: "square") { crop = PhotoCropGeometry.square(for: image.size) }
                    Button("Completa", systemImage: "arrow.counterclockwise") { crop = PhotoCropGeometry.full }
                }.buttonStyle(.bordered)
                VStack(spacing: 8) {
                    HStack {
                        Text("Ancho").frame(width: 56, alignment: .leading)
                        Slider(value: Binding(get: { crop.width }, set: {
                            crop.size.width = $0
                            crop.origin.x = min(crop.minX, 1 - $0)
                        }), in: 0.08...1).accessibilityLabel("Ancho del recorte")
                    }
                    HStack {
                        Text("Alto").frame(width: 56, alignment: .leading)
                        Slider(value: Binding(get: { crop.height }, set: {
                            crop.size.height = $0
                            crop.origin.y = min(crop.minY, 1 - $0)
                        }), in: 0.08...1).accessibilityLabel("Alto del recorte")
                    }
                }.font(.caption)
                if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
            .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle("Recortar foto").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Usar foto") {
                        guard let result = PhotoCropGeometry.cropped(image, rect: crop) else {
                            errorMessage = "No se pudo recortar la foto. Probá restablecer el marco."
                            return
                        }
                        onConfirm(result)
                    }.accessibilityIdentifier("editor.confirmCrop")
                }
            }
        }
        .presentationBackground(Color(uiColor: .systemBackground))
    }

    private func cropOverlay(size: CGSize) -> some View {
        let rect = CGRect(x: crop.minX * size.width, y: crop.minY * size.height,
                          width: crop.width * size.width, height: crop.height * size.height)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.clear).contentShape(Rectangle())
                .overlay { Rectangle().strokeBorder(.white, lineWidth: 2) }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .gesture(drag(size: size, corner: nil))
                .accessibilityLabel("Marco del recorte")
                .accessibilityHint("Arrastrá para mover el recorte dentro de la foto.")
            handle(size: size, topLeft: true).position(x: rect.minX, y: rect.minY)
            handle(size: size, topLeft: false).position(x: rect.maxX, y: rect.maxY)
        }.frame(width: size.width, height: size.height)
    }

    private func handle(size: CGSize, topLeft: Bool) -> some View {
        Circle().fill(.white).frame(width: 22, height: 22)
            .overlay { Circle().strokeBorder(.black.opacity(0.65)) }
            .frame(width: 44, height: 44).contentShape(Rectangle())
            .gesture(drag(size: size, corner: topLeft))
            .accessibilityLabel(topLeft ? "Esquina superior del recorte" : "Esquina inferior del recorte")
    }

    private func drag(size: CGSize, corner: Bool?) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("photoCropCanvas"))
            .onChanged { value in
                if dragStart == nil { dragStart = crop }
                guard let start = dragStart, size.width > 0, size.height > 0 else { return }
                let offset = CGSize(width: value.translation.width / size.width, height: value.translation.height / size.height)
                if let corner { crop = PhotoCropGeometry.resized(start, by: offset, topLeft: corner) }
                else { crop = PhotoCropGeometry.moved(start, by: offset) }
            }
            .onEnded { _ in dragStart = nil }
    }
}

private struct CropShade: Shape {
    let rect: CGRect
    func path(in bounds: CGRect) -> Path {
        var path = Path(bounds)
        path.addRect(CGRect(x: rect.minX * bounds.width, y: rect.minY * bounds.height,
                            width: rect.width * bounds.width, height: rect.height * bounds.height))
        return path
    }
}
