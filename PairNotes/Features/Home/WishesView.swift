import PairNotesCore
import PhotosUI
import SafariServices
import SwiftUI
import UIKit

/// Production and simulator fixtures share every view and mutation path.
@MainActor
struct WishSource {
    var currentScope: () -> String
    var isAuthorized: () -> Bool
    var draftKey: (String) -> String
    var list: () async throws -> [CoupleWish]
    var save: (WishFields, String, Int, UUID) async throws -> CoupleWish
    var delete: (CoupleWish, UUID) async throws -> Void
    var uploadPhoto: (Data, CoupleWish, UUID) async throws -> CoupleWish
    var removePhoto: (CoupleWish, UUID) async throws -> CoupleWish
    var photo: (CoupleWish) async throws -> UIImage?

    static func live(_ services: AppServices) -> Self {
        Self(currentScope: { services.privateImageKey("wishes") },
             isAuthorized: { services.membershipResolved && services.membership != nil && services.identity != nil },
             draftKey: { services.privateImageKey("wish-draft:" + $0) },
             list: { try await services.wishes() },
             save: { fields, id, revision, request in
                 let values = try fields.validated()
                 return try await services.saveWish(id: id, title: values.title, category: values.category,
                     notes: values.notes, priceAmount: values.priceText.isEmpty ? nil : values.priceText,
                     currencyCode: values.currencyCode, fulfilled: values.fulfilled,
                     expectedRevision: revision, requestID: request,
                     linkURL: values.linkText.isEmpty ? nil : values.linkText, targetDate: values.targetDate,
                     location: values.location, savedAmount: values.savedText.isEmpty ? nil : values.savedText,
                     recipient: values.recipient, occasion: values.occasion, foodKind: values.foodKind,
                     ingredients: values.ingredients, instructions: values.instructions)
             }, delete: { try await services.deleteWish($0, requestID: $1) },
             uploadPhoto: { try await services.uploadWishPhoto($0, to: $1, requestID: $2) },
             removePhoto: { try await services.removeWishPhoto($0, requestID: $1) },
             photo: { try await services.wishPhoto($0) })
    }
}

struct WishFields: Codable, Equatable {
    var title = ""
    var category: CoupleWishCategory = .other
    var notes = ""
    var priceText = ""
    var currencyCode: String?
    var fulfilled = false
    var linkText = ""
    var targetDate: CoupleDate?
    var location = ""
    var savedText = ""
    var recipient = ""
    var occasion = ""
    var foodKind: CoupleWishFoodKind? = .restaurant
    var ingredients = ""
    var instructions = ""
    // A pending request must keep interpreting its original decimal separator,
    // even if the phone's region changes before the response is recovered.
    var numberLocaleIdentifier = Locale.current.identifier

    init(category: CoupleWishCategory = .other) { self.category = category }

    init(_ wish: CoupleWish) {
        title = wish.title; category = wish.category; notes = wish.notes
        priceText = wish.priceAmount.map { CoupleWishPrice.editable(amount: $0) } ?? ""
        currencyCode = wish.currencyCode; fulfilled = wish.fulfilled
        linkText = wish.linkURL ?? ""; targetDate = wish.targetDate; location = wish.location
        savedText = wish.savedAmount.map { CoupleWishPrice.editable(amount: $0) } ?? ""
        recipient = wish.recipient; occasion = wish.occasion
        foodKind = wish.foodKind ?? .restaurant; ingredients = wish.ingredients; instructions = wish.instructions
    }

    var usesDate: Bool { category == .travel || category == .plans || category == .gifts || (category == .food && foodKind != .recipe) }
    var usesLocation: Bool { category == .travel || category == .plans || (category == .food && foodKind != .recipe) }
    var priceTitle: String { category == .travel ? "Presupuesto" : "Precio estimado" }

    func validated(locale override: Locale? = nil) throws -> Self {
        let locale = override ?? Locale(identifier: numberLocaleIdentifier)
        var value = self
        value.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.title.isEmpty, value.title.utf16.count <= 120 else { throw WishFormError("Escribí un título de hasta 120 caracteres.") }
        guard notes.utf16.count <= 1_000 else { throw WishFormError("Las notas pueden tener hasta 1000 caracteres.") }
        guard (!usesLocation || location.utf16.count <= 240),
              (category != .gifts || (recipient.utf16.count <= 120 && occasion.utf16.count <= 120)) else {
            throw WishFormError("El lugar admite hasta 240 caracteres; el destinatario y la ocasión, hasta 120.")
        }
        guard category != .food || foodKind != .recipe ||
              (ingredients.utf16.count <= 6_000 && instructions.utf16.count <= 10_000) else {
            throw WishFormError("Usá hasta 6000 caracteres para ingredientes y 10000 para la preparación.")
        }
        value.priceText = try CoupleWishPrice.parse(priceText, locale: locale) ?? ""
        value.savedText = category == .travel ? (try CoupleWishPrice.parse(savedText, locale: locale) ?? "") : ""
        if !value.priceText.isEmpty || !value.savedText.isEmpty {
            guard let currencyCode, CoupleWishPrice.isCurrencyCode(currencyCode) else {
                throw WishFormError("Elegí la moneda de este antojo.")
            }
        } else { value.currencyCode = nil }
        if !value.savedText.isEmpty, value.priceText.isEmpty {
            throw WishFormError("Agregá el presupuesto para registrar cuánto llevan ahorrado.")
        }
        value.linkText = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.linkText.isEmpty, !CoupleWish.isPublicLink(value.linkText) {
            throw WishFormError("Usá un enlace completo que empiece con https:// o http://.")
        }
        if !usesDate { value.targetDate = nil }
        if !usesLocation { value.location = "" }
        if category != .gifts { value.recipient = ""; value.occasion = "" }
        if category != .food { value.foodKind = nil }
        if category != .food || foodKind != .recipe { value.ingredients = ""; value.instructions = "" }
        return value
    }

    mutating func localizeNumbers(to locale: Locale) {
        guard numberLocaleIdentifier != locale.identifier else { return }
        let previous = Locale(identifier: numberLocaleIdentifier)
        // Leave invalid working text intact, with its original input locale.
        // A draft is allowed to contain a partially entered decimal number.
        do {
            let price = try CoupleWishPrice.parse(priceText, locale: previous)
            let saved = try CoupleWishPrice.parse(savedText, locale: previous)
            priceText = price.map { CoupleWishPrice.editable(amount: $0, locale: locale) } ?? ""
            savedText = saved.map { CoupleWishPrice.editable(amount: $0, locale: locale) } ?? ""
            numberLocaleIdentifier = locale.identifier
        } catch { return }
    }
}

private struct WishFormError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum WishWebAddress {
    static func url(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              ["https", "http"].contains(scheme), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }
}

struct WishesView: View {
    @ObservedObject private var services: AppServices
    private let source: WishSource
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.coupleModalControl) private var modalControl
    @State private var values: [CoupleWish] = []
    @State private var loadedScope: String?
    @State private var loading = false
    @State private var hasLoaded = false
    @State private var error: String?
    @State private var category: CoupleWishCategory?
    @State private var showsFulfilled = false
    @State private var creating = false
    @State private var selected: CoupleWish?
    @State private var version: UInt64 = 0
    @State private var modalOwner = UUID()

    init(services: AppServices, source: WishSource? = nil) {
        self.services = services; self.source = source ?? .live(services)
    }

    private var scope: String { source.currentScope() }
    private var theme: CoupleTheme { services.personalization.theme }
    private var currentValues: [CoupleWish] { loadedScope == scope ? values : [] }
    private var visibleValues: [CoupleWish] {
        currentValues.filter { $0.fulfilled == showsFulfilled && (category == nil || $0.category == category) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nuestros antojos").font(.largeTitle.bold())
                    Text("Ideas para disfrutar, regalar y cumplir juntos.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                categoryFilters
                Picker("Ver antojos", selection: $showsFulfilled) {
                    Text("Por cumplir").tag(false)
                    Text("Cumplidos").tag(true)
                }.pickerStyle(.segmented).accessibilityIdentifier("wishes.status")
                if loading && !hasLoaded {
                    ProgressView("Buscando sus antojos…").frame(maxWidth: .infinity, minHeight: 160)
                } else if !source.isAuthorized() {
                    ContentUnavailableView("Para compartir entre dos", systemImage: "heart.text.square",
                        description: Text("Vinculá sus cuentas para guardar sus antojos juntos."))
                } else if visibleValues.isEmpty && (error == nil || hasLoaded) {
                    ContentUnavailableView {
                        Label(showsFulfilled ? "Los sueños cumplidos van acá" : "El próximo plan empieza acá", systemImage: showsFulfilled ? "checkmark.seal" : "sparkles")
                    } description: {
                        Text(category == nil ? "Guardá una idea que les ilusione, con foto, detalles y su moneda." : "Todavía no hay antojos en esta categoría.")
                    } actions: {
                        if !showsFulfilled { Button("Nuevo antojo", systemImage: "plus", action: create).buttonStyle(.borderedProminent) }
                    }
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 16) {
                        ForEach(visibleValues) { wish in
                            Button { modalControl.onPresented(modalOwner); selected = wish } label: {
                                WishCard(wish: wish, source: source)
                            }.buttonStyle(.plain).accessibilityIdentifier("wish.card.\(wish.id)")
                        }
                    }.accessibilityIdentifier("wishes.grid")
                }
                if let error {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "wifi.exclamationmark").font(.callout).foregroundStyle(.secondary)
                        Button("Reintentar") { Task { await load() } }.buttonStyle(.bordered).disabled(loading)
                    }.accessibilityIdentifier("wishes.error")
                }
            }.frame(maxWidth: 740).frame(maxWidth: .infinity).padding(20)
        }
        .coupleScreenBackground().foregroundStyle(theme.ink)
        .navigationTitle("Antojos").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Nuevo antojo", systemImage: "plus", action: create)
                    .disabled(!source.isAuthorized()).accessibilityIdentifier("wishes.add")
            }
        }
        .refreshable { await load() }
        .task(id: "\(scope):\(scenePhase == .active)") {
            guard scenePhase == .active else { return }
            if loadedScope != scope { values = []; hasLoaded = false; loading = false; error = nil; version &+= 1 }
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await load()
            }
        }
        .onChange(of: scope) { _, _ in selected = nil; creating = false }
        .onChange(of: modalControl.dismissalVersion) { _, _ in selected = nil; creating = false }
        .sheet(isPresented: $creating, onDismiss: sheetDismissed) {
            WishEditorView(source: source, initialCategory: category ?? .other, onSaved: accept)
                .environment(\.coupleAppTheme, theme)
        }
        .sheet(item: $selected, onDismiss: sheetDismissed) { wish in
            WishDetailView(wish: wish, source: source, onChanged: accept, onDeleted: { id in
                version &+= 1; values.removeAll { $0.id == id }
            }).environment(\.coupleAppTheme, theme)
        }
    }

    private func create() {
        guard source.isAuthorized() else { return }
        modalControl.onPresented(modalOwner)
        creating = true
    }

    private func sheetDismissed() {
        modalControl.onDismissed(modalOwner)
        Task { await load() }
    }

    private var categoryFilters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                categoryChip("Todos", symbol: "square.grid.2x2", value: nil)
                ForEach(CoupleWishCategory.allCases, id: \.self) { item in
                    categoryChip(item.title, symbol: item.symbol, value: item)
                }
            }
        }.scrollIndicators(.hidden).accessibilityIdentifier("wishes.categories")
    }

    private func categoryChip(_ title: String, symbol: String, value: CoupleWishCategory?) -> some View {
        Button { category = value } label: {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).frame(minHeight: 44)
                .background(category == value ? theme.accent.opacity(0.18) : theme.card, in: Capsule())
                .overlay(Capsule().strokeBorder(category == value ? theme.accent : .clear, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityAddTraits(category == value ? .isSelected : [])
            .accessibilityIdentifier("wishes.category.\(value?.rawValue ?? "all")")
    }

    private func load() async {
        guard source.isAuthorized(), !loading, !Task.isCancelled else { return }
        let key = scope, requestVersion = version
        loading = true
        defer { if scope == key { loading = false } }
        do {
            let received = try await source.list()
            guard !Task.isCancelled, scope == key, requestVersion == version else { return }
            values = received; loadedScope = key; hasLoaded = true; error = nil
        } catch {
            if !Task.isCancelled, scope == key { self.error = "No se pudieron actualizar los antojos. Tus cambios guardados siguen disponibles." }
        }
    }

    private func accept(_ wish: CoupleWish) {
        guard source.isAuthorized() else { return }
        version &+= 1; loadedScope = scope; hasLoaded = true
        if let index = values.firstIndex(where: { $0.id == wish.id }) {
            if wish.revision >= values[index].revision { values[index] = wish }
        }
        else { values.insert(wish, at: 0) }
    }
}

struct WishCard: View {
    let wish: CoupleWish
    let source: WishSource
    @Environment(\.coupleAppTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WishPhotoView(wish: wish, source: source)
                .frame(height: dynamicTypeSize.isAccessibilitySize ? 210 : 138).clipped()
                .overlay(alignment: .topTrailing) {
                    if wish.fulfilled { Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.white, theme.accent).padding(10) }
                }
            VStack(alignment: .leading, spacing: 8) {
                Label(wish.category.title, systemImage: wish.category.symbol)
                    .font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
                Text(wish.title).font(.headline).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let amount = wish.priceAmount, let code = wish.currencyCode {
                    Text(WishMoney.label(amount, code: code)).font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if wish.category == .travel, let remaining = wish.remainingAmount, let code = wish.currencyCode {
                    Text("Faltan \(WishMoney.label(remaining, code: code))").font(.caption).foregroundStyle(.secondary)
                }
                if let date = wish.targetDate?.date() {
                    Text(date, format: .dateTime.day().month().year()).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(14)
        }.background(theme.card, in: RoundedRectangle(cornerRadius: 22))
            .clipShape(RoundedRectangle(cornerRadius: 22)).privacySensitive()
            .accessibilityElement(children: .combine)
    }
}

enum WishMoney {
    static func label(_ amount: String, code: String) -> String {
        let formatted = CoupleWishPrice.format(amount: amount, currencyCode: code)
        return formatted.contains(code) ? formatted : "\(formatted) \(code)"
    }
}

struct WishPhotoView: View {
    let wish: CoupleWish
    let source: WishSource
    @Environment(\.coupleAppTheme) private var theme
    @State private var image: UIImage?
    @State private var loadedKey: String?
    @State private var failed = false
    @State private var retry = 0
    var allowsRetry = false
    private var key: String { "\(source.currentScope()):\(wish.id):\(wish.photo?.id ?? "none")" }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                theme.accent.opacity(0.1)
                if loadedKey == key, let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: wish.category.symbol).font(.system(size: 38, weight: .light)).foregroundStyle(theme.accent)
                        if failed && allowsRetry {
                            Button("Reintentar foto") { retry += 1 }.font(.caption).buttonStyle(.bordered)
                        }
                    }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.clipped().privacySensitive().accessibilityLabel(wish.photo == nil ? wish.category.title : "Foto de \(wish.title)")
            .task(id: "\(key):\(retry)") {
                let captured = key; image = nil; loadedKey = nil; failed = false
                guard wish.photo != nil else { return }
                do {
                    let received = try await source.photo(wish)
                    guard !Task.isCancelled, key == captured else { return }
                    image = received; loadedKey = captured; failed = received == nil
                } catch { if !Task.isCancelled, key == captured { failed = true } }
            }
    }
}

struct WishDetailView: View {
    @State var wish: CoupleWish
    let source: WishSource
    let onChanged: (CoupleWish) -> Void
    let onDeleted: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.coupleAppTheme) private var theme
    @State private var editing = false
    @State private var confirmsDelete = false
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var operation: String?
    @State private var browser: WishBrowserTarget?
    @State private var initialScope: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    WishPhotoView(wish: wish, source: source, allowsRetry: true)
                        .frame(height: 250).clipShape(RoundedRectangle(cornerRadius: 26))
                    Label(wish.category.title, systemImage: wish.category.symbol).font(.subheadline.weight(.semibold)).foregroundStyle(theme.accent)
                    Text(wish.title).font(.largeTitle.bold()).accessibilityIdentifier("wish.detail.title")
                    if let amount = wish.priceAmount, let code = wish.currencyCode {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(wish.category == .travel ? "Presupuesto" : "Precio estimado").font(.caption).foregroundStyle(.secondary)
                            Text(WishMoney.label(amount, code: code)).font(.title2.bold()).accessibilityIdentifier("wish.detail.price")
                        }
                    }
                    if wish.category == .travel, let amount = wish.priceAmount, let code = wish.currencyCode {
                        travelSavings(amount: amount, currency: code)
                    }
                    if !wish.location.isEmpty { information(wish.category == .travel ? "Destino" : "Lugar", value: wish.location, symbol: "mappin.and.ellipse") }
                    if let date = wish.targetDate?.date() {
                        information("Fecha", value: date.formatted(date: .long, time: .omitted), symbol: "calendar")
                            .accessibilityIdentifier("wish.detail.date")
                    }
                    if !wish.recipient.isEmpty { information("Para", value: wish.recipient, symbol: "person") }
                    if !wish.occasion.isEmpty { information("Ocasión", value: wish.occasion, symbol: "gift") }
                    if wish.foodKind == .recipe {
                        if !wish.ingredients.isEmpty { information("Ingredientes", value: wish.ingredients, symbol: "carrot") }
                        if !wish.instructions.isEmpty { information("Preparación", value: wish.instructions, symbol: "list.number") }
                    }
                    if !wish.notes.isEmpty { information("Notas", value: wish.notes, symbol: "text.alignleft") }
                    if let address = wish.linkURL, let url = WishWebAddress.url(address) {
                        Button { browser = WishBrowserTarget(url: url) } label: {
                            Label("Abrir publicación", systemImage: "safari").frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.bordered).accessibilityIdentifier("wish.detail.link")
                    }
                    Button { changeFulfilled() } label: {
                        Label(wish.fulfilled ? "Volver a pendientes" : "¡Lo cumplimos!", systemImage: wish.fulfilled ? "arrow.uturn.backward" : "checkmark.circle")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.borderedProminent).disabled(busy).accessibilityIdentifier("wish.fulfill")
                    if busy { ProgressView("Guardando…") }
                    if let error { Text(error).font(.callout).foregroundStyle(.red).accessibilityIdentifier("wish.detail.error") }
                    Button("Eliminar antojo", role: .destructive) { confirmsDelete = true }
                        .frame(maxWidth: .infinity, minHeight: 44).disabled(busy).accessibilityIdentifier("wish.delete")
                }.padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.coupleScreenBackground().privacySensitive()
                .navigationTitle("Antojo").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .primaryAction) { Button("Editar") { editing = true }.disabled(busy).accessibilityIdentifier("wish.edit") }
                }
                .interactiveDismissDisabled(busy)
                .onAppear { if initialScope == nil { initialScope = source.currentScope() } }
                .onChange(of: source.currentScope()) { _, _ in dismiss() }
                .sheet(isPresented: $editing) {
                    WishEditorView(source: source, original: wish, onSaved: { value in
                        wish = value; onChanged(value); operation = nil; requestID = UUID(); error = nil
                    })
                }
                .sheet(item: $browser) { WishWebLinkView(url: $0.url).ignoresSafeArea() }
                .confirmationDialog("¿Eliminar este antojo para los dos?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                    Button("Eliminar antojo", role: .destructive) { delete() }
                }
        }
    }

    private func information(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func travelSavings(amount: String, currency: String) -> some View {
        let budget = NSDecimalNumber(string: amount).doubleValue
        let saved = NSDecimalNumber(string: wish.savedAmount ?? "0").doubleValue
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ahorrado"); Spacer()
                Text(WishMoney.label(wish.savedAmount ?? "0", code: currency)).fontWeight(.semibold)
                    .accessibilityIdentifier("wish.detail.saved")
            }
            ProgressView(value: budget > 0 ? min(1, max(0, saved / budget)) : (saved > 0 ? 1 : 0))
                .tint(theme.accent).accessibilityLabel("Ahorro para el viaje")
            if let remaining = wish.remainingAmount {
                Text("Nos faltan \(WishMoney.label(remaining, code: currency))").font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("wish.detail.remaining")
            }
        }.padding(16).background(theme.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private var current: Bool { source.isAuthorized() && initialScope == source.currentScope() }
    private func begin(_ name: String) -> Bool {
        guard current, !busy else { return false }
        if operation != name { requestID = UUID(); operation = name }
        busy = true; error = nil
        return true
    }
    private func changeFulfilled() {
        guard begin("fulfilled") else { return }
        let key = source.currentScope(), id = requestID
        var fields = WishFields(wish); fields.fulfilled.toggle()
        Task { @MainActor in
            defer { busy = false }
            do {
                let updated = try await source.save(fields, wish.id, wish.revision, id)
                guard current, source.currentScope() == key else { return }
                wish = updated; onChanged(updated); operation = nil
            } catch { if current { self.error = WishFailure.message(error) } }
        }
    }
    private func delete() {
        guard begin("delete") else { return }
        let key = source.currentScope(), id = requestID
        Task { @MainActor in
            defer { busy = false }
            do {
                try await source.delete(wish, id)
                guard current, source.currentScope() == key else { return }
                onDeleted(wish.id); dismiss()
            } catch { if current { self.error = WishFailure.message(error) } }
        }
    }
}

private enum WishFailure {
    static func message(_ error: Error) -> String {
        if let failure = error as? WishFormError { return failure.message }
        if let api = error as? APIError, api.status == 409 {
            return "Este antojo cambió en el otro iPhone. Cerrá y volvé a abrirlo para ver la versión actual; tus cambios locales se conservan."
        }
        return "No se pudo confirmar el cambio. Tus datos se conservan; volvé a intentar."
    }

    static func isDefiniteRejection(_ error: Error) -> Bool {
        if error is WishFormError || error is CoupleWishPriceError || error is AccountDomainError { return true }
        // Authentication/rate limits may reject a retry before its previously
        // accepted request is looked up. Keep that operation's idempotency key.
        if let api = error as? APIError { return [400, 404, 409, 413, 415, 422].contains(api.status) }
        return false
    }
}

private struct WishEditorDraft: Codable {
    var id = UUID().uuidString.lowercased()
    var fields: WishFields
    var base: CoupleWish?
    var metadataRequest = UUID()
    var photoRequest = UUID()
    var metadataConfirmed = false
    var pendingMetadata = false
    var pendingPhoto = false
    var needsReview = false
    var photoAction = "keep"
}

private struct WishEditorContext {
    let scope: String
    let storage: MemoryCompositionStorage
}

struct WishEditorView: View {
    let source: WishSource
    let original: CoupleWish?
    let onSaved: (CoupleWish) -> Void
    @State private var context: WishEditorContext
    private var storage: MemoryCompositionStorage { context.storage }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.coupleAppTheme) private var theme
    @State private var draft: WishEditorDraft
    @State private var photoData: Data?
    @State private var photoDirty = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var preparingPhoto = false
    @State private var saving = false
    @State private var persistenceFailed = false
    @State private var finished = false
    @State private var error: String?
    @State private var choosingCurrency = false
    @State private var confirmsDiscard = false
    @State private var confirmsReload = false
    @State private var conflict = false
    @FocusState private var field: String?

    init(source: WishSource, original: CoupleWish? = nil, initialCategory: CoupleWishCategory = .other,
         onSaved: @escaping (CoupleWish) -> Void) {
        self.source = source; self.original = original; self.onSaved = onSaved
        var storage = MemoryCompositionStorage(key: source.draftKey(original?.id ?? "new"))
        var recovered: WishEditorDraft? = storage.loadValue()
        if recovered == nil, let original {
            // Metadata may be confirmed before a create's photo finishes.
            // Opening that card resumes the original pending request and image.
            let creation = MemoryCompositionStorage(key: source.draftKey("new"))
            if let pending: WishEditorDraft = creation.loadValue(), pending.id == original.id {
                storage = creation; recovered = pending
            }
        }
        _context = State(initialValue: WishEditorContext(scope: source.currentScope(), storage: storage))
        var initial = recovered ?? WishEditorDraft(id: original?.id ?? UUID().uuidString.lowercased(),
            fields: original.map(WishFields.init) ?? WishFields(category: initialCategory), base: original)
        if !initial.pendingMetadata && !initial.pendingPhoto { initial.fields.localizeNumbers(to: .current) }
        initial.needsReview = initial.needsReview || (!initial.pendingMetadata && !initial.pendingPhoto &&
            (original?.revision ?? 0) > (initial.base?.revision ?? 0))
        _draft = State(initialValue: initial)
        _photoData = State(initialValue: initial.photoAction == "replace" ? storage.photo() : nil)
        _conflict = State(initialValue: initial.needsReview)
    }

    private var current: Bool { source.isAuthorized() && context.scope == source.currentScope() }
    private var fieldsLocked: Bool { saving || draft.pendingMetadata || draft.pendingPhoto }
    private var ready: Bool { current && !saving && !preparingPhoto && !conflict && (try? draft.fields.validated()) != nil }
    private var validationHint: String? {
        guard !draft.fields.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do { _ = try draft.fields.validated(); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        NavigationStack {
            Form {
                photoSection
                Section("La idea") {
                    TextField("¿Qué se les antoja?", text: $draft.fields.title, axis: .vertical)
                        .lineLimit(1...3).focused($field, equals: "title").accessibilityIdentifier("wish.form.title")
                    Picker("Categoría", selection: $draft.fields.category) {
                        ForEach(CoupleWishCategory.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }.accessibilityIdentifier("wish.form.category")
                }.disabled(fieldsLocked)
                categorySection.disabled(fieldsLocked)
                priceSection.disabled(fieldsLocked)
                Section("Notas") {
                    TextField("Algo más para recordar (opcional)", text: $draft.fields.notes, axis: .vertical)
                        .lineLimit(3...8).focused($field, equals: "notes").accessibilityIdentifier("wish.form.notes")
                    if draft.fields.notes.utf16.count > 850 { Text("\(draft.fields.notes.utf16.count)/1000").font(.caption).foregroundStyle(.secondary) }
                }.disabled(fieldsLocked)
                Section {
                    if let hint = validationHint { Text(hint).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("wish.form.validation") }
                    if draft.pendingMetadata || draft.pendingPhoto { Text("Guardado sin confirmar. Reintentá para recuperar la misma versión.").font(.callout).foregroundStyle(.secondary) }
                    if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("wish.form.error") }
                    if conflict {
                        Text("Tus cambios están guardados en este iPhone. Podés conservarlos o cargar la versión compartida.").font(.callout)
                        Button("Cargar versión compartida") { confirmsReload = true }.disabled(saving)
                    }
                    Button { save() } label: {
                        HStack { Spacer(); if saving { ProgressView() } else { Text(draft.pendingMetadata || draft.pendingPhoto ? "Reintentar guardado" : "Guardar antojo").fontWeight(.semibold) }; Spacer() }
                            .frame(minHeight: 44)
                    }.disabled(!ready).accessibilityIdentifier("wish.form.save")
                    Button("Descartar cambios locales", role: .destructive) { confirmsDiscard = true }.disabled(saving)
                        .accessibilityIdentifier("wish.form.discard")
                }
            }.scrollDismissesKeyboard(.interactively).scrollContentBackground(.hidden).coupleScreenBackground()
                .navigationTitle(original == nil ? "Nuevo antojo" : "Editar antojo").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cerrar") { if persist() { dismiss() } }.disabled(saving).accessibilityIdentifier("wish.form.close")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { save() } label: { if saving { ProgressView() } else { Text("Guardar") } }
                            .disabled(!ready).accessibilityIdentifier("wish.form.save.toolbar")
                    }
                }
                .interactiveDismissDisabled(saving || persistenceFailed)
                .onChange(of: draft.fields) { _, _ in
                    guard !saving else { return }
                    draft.metadataConfirmed = false; draft.metadataRequest = UUID()
                    _ = persist()
                }
                .onDisappear { if !finished { _ = persist() } }
                .onChange(of: source.currentScope()) { _, _ in dismiss() }
                .task(id: photoSelection) { await importPhoto() }
                .sheet(isPresented: $choosingCurrency) { WishCurrencyPicker(selection: $draft.fields.currencyCode) }
                .confirmationDialog("¿Descartar los cambios de este iPhone?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                    Button("Descartar cambios", role: .destructive) { finished = true; storage.clear(); dismiss() }
                } message: { Text(draft.base == nil ? "Se elimina este borrador del iPhone." : "El antojo compartido sigue guardado.") }
                .confirmationDialog("¿Reemplazar tus cambios por la versión compartida?", isPresented: $confirmsReload, titleVisibility: .visible) {
                    Button("Cargar versión compartida", role: .destructive) { reload() }
                }
        }
        .opacity(current ? 1 : 0)
        .allowsHitTesting(current)
        .accessibilityHidden(!current)
    }

    private var photoSection: some View {
        Section {
            GeometryReader { geometry in
                Group {
                    if let photoData, let image = UIImage(data: photoData), draft.photoAction == "replace" {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    } else if let base = draft.base, base.photo != nil, draft.photoAction != "remove" {
                        WishPhotoView(wish: base, source: source, allowsRetry: true)
                    } else {
                        ZStack { theme.accent.opacity(0.1); Label("Una foto para inspirarse", systemImage: "photo").foregroundStyle(theme.accent) }
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }.frame(height: 190).clipShape(RoundedRectangle(cornerRadius: 18))
            PhotosPicker(selection: $photoSelection, matching: .images) {
                Label(photoData != nil || draft.base?.photo != nil ? "Cambiar foto" : "Elegir foto", systemImage: "photo.on.rectangle")
                    .frame(minHeight: 44)
            }.disabled(fieldsLocked || preparingPhoto).accessibilityIdentifier("wish.form.photo")
            if preparingPhoto { ProgressView("Preparando foto…") }
            if photoData != nil || (draft.base?.photo != nil && draft.photoAction != "remove") {
                Button("Quitar foto", role: .destructive) {
                    photoData = nil; photoDirty = true; photoSelection = nil
                    draft.photoAction = draft.base?.photo == nil ? "keep" : "remove"
                    draft.photoRequest = UUID(); _ = persist()
                }.disabled(fieldsLocked || preparingPhoto)
            }
        }
    }

    @ViewBuilder private var categorySection: some View {
        switch draft.fields.category {
        case .gifts:
            Section("El regalito") {
                TextField("Para quién (opcional)", text: $draft.fields.recipient).accessibilityIdentifier("wish.form.recipient")
                TextField("Ocasión (opcional)", text: $draft.fields.occasion)
                dateField
                linkField
            }
        case .travel:
            Section("El viaje") {
                TextField("Destino (opcional)", text: $draft.fields.location).accessibilityIdentifier("wish.form.location")
                dateField
                linkField
            }
        case .food:
            Section("Para compartir a la mesa") {
                Picker("Tipo de antojo", selection: Binding(get: { draft.fields.foodKind ?? .restaurant }, set: { draft.fields.foodKind = $0 })) {
                    Text("Restaurante").tag(CoupleWishFoodKind.restaurant)
                    Text("Receta").tag(CoupleWishFoodKind.recipe)
                }.pickerStyle(.segmented).accessibilityIdentifier("wish.form.food-kind")
                if draft.fields.foodKind == .recipe {
                    TextField("Ingredientes (opcional)", text: $draft.fields.ingredients, axis: .vertical).lineLimit(3...8)
                        .accessibilityIdentifier("wish.form.ingredients")
                    TextField("Preparación (opcional)", text: $draft.fields.instructions, axis: .vertical).lineLimit(3...12)
                        .accessibilityIdentifier("wish.form.instructions")
                } else {
                    TextField("Restaurante o lugar (opcional)", text: $draft.fields.location).accessibilityIdentifier("wish.form.location")
                    dateField
                }
                linkField
            }
        case .plans:
            Section("El plan") {
                TextField("Lugar (opcional)", text: $draft.fields.location).accessibilityIdentifier("wish.form.location")
                dateField
                linkField
            }
        case .home, .other:
            Section("Dónde encontrarlo") { linkField }
        }
    }

    private var linkField: some View {
        TextField("Enlace de la publicación (opcional)", text: $draft.fields.linkText)
            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            .focused($field, equals: "link").accessibilityIdentifier("wish.form.link")
    }
    private var dateField: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Elegir fecha", isOn: Binding(get: { draft.fields.targetDate != nil }, set: {
                draft.fields.targetDate = $0 ? CoupleDate(date: Date()) : nil
            })).accessibilityIdentifier("wish.form.has-date")
            if draft.fields.targetDate != nil {
                DatePicker("Fecha", selection: Binding(get: { draft.fields.targetDate?.date() ?? Date() },
                    set: { draft.fields.targetDate = CoupleDate(date: $0) }), displayedComponents: .date)
                    .accessibilityIdentifier("wish.form.date")
            }
        }
    }
    private var priceSection: some View {
        Section {
            TextField("Importe (opcional)", text: $draft.fields.priceText)
                .keyboardType(.decimalPad).focused($field, equals: "price").accessibilityIdentifier("wish.form.price")
            Button { field = nil; choosingCurrency = true } label: {
                HStack {
                    Text("Moneda")
                    Spacer()
                    Text(draft.fields.currencyCode ?? "Elegir moneda").foregroundStyle(draft.fields.currencyCode == nil ? .secondary : theme.ink)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }.frame(minHeight: 44)
            }.buttonStyle(.plain).accessibilityIdentifier("wish.form.currency")
            if draft.fields.category == .travel {
                TextField("Ahorrado (opcional)", text: $draft.fields.savedText)
                    .keyboardType(.decimalPad).focused($field, equals: "saved").accessibilityIdentifier("wish.form.saved")
            }
        } header: { Text(draft.fields.priceTitle) } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.fields.category == .travel ? "Presupuesto y ahorro usan la moneda que elijas para este viaje." : "Cada antojo tiene su propia moneda. Podés guardarlo sin precio.")
                if draft.fields.numberLocaleIdentifier != Locale.current.identifier {
                    Text("Este borrador usa \(Locale(identifier: draft.fields.numberLocaleIdentifier).decimalSeparator == "," ? "coma" : "punto") decimal.")
                }
            }
        }
    }

    private func importPhoto() async {
        guard let selection = photoSelection, current, !fieldsLocked else { return }
        preparingPhoto = true; error = nil
        defer { preparingPhoto = false }
        do {
            guard let bytes = try await selection.loadTransferable(type: Data.self) else { throw ServiceError.invalidResponse }
            try Task.checkCancellation()
            let data = try SelectedPhoto.jpeg(bytes)
            guard current, !Task.isCancelled else { return }
            photoData = data; photoDirty = true; draft.photoAction = "replace"; draft.photoRequest = UUID(); _ = persist()
        } catch {
            if !Task.isCancelled, current { self.error = "No se pudo preparar la foto. Elegí otra o volvé a intentar si está en iCloud." }
        }
    }

    @discardableResult private func persist() -> Bool {
        guard current, !finished else { return false }
        do {
            if photoDirty { try storage.savePhoto(photoData); photoDirty = false }
            try storage.saveValue(draft)
            persistenceFailed = false
            return true
        } catch {
            persistenceFailed = true
            self.error = "No se pudo guardar el borrador en este iPhone. Reintentá antes de cerrar."
            return false
        }
    }

    private func save() {
        guard ready, persist() else { return }
        field = nil; saving = true; error = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                guard current else { return }
                if !draft.metadataConfirmed {
                    draft.pendingMetadata = true
                    guard persist() else { return }
                    let expectedRevision = draft.base?.revision ?? 0
                    let saved = try await source.save(draft.fields, draft.id, expectedRevision, draft.metadataRequest)
                    guard current, !Task.isCancelled else { return }
                    draft.base = saved; draft.metadataConfirmed = true; draft.pendingMetadata = false
                    onSaved(saved)
                    guard persist() else { return }
                    if saved.revision > expectedRevision + 1, draft.photoAction != "keep" {
                        // An idempotent retry can return a later partner edit.
                        // Do not use that newer revision to replace their photo.
                        conflict = true
                        draft.needsReview = true
                        error = "El antojo cambió mientras se confirmaba el guardado. Revisá la versión compartida antes de cambiar su foto."
                        _ = persist()
                        return
                    }
                }
                guard var saved = draft.base else { throw ServiceError.invalidResponse }
                if draft.photoAction == "replace" {
                    guard let photoData else { throw WishFormError("Volvé a elegir la foto antes de guardar.") }
                    draft.pendingPhoto = true
                    guard persist() else { return }
                    saved = try await source.uploadPhoto(photoData, saved, draft.photoRequest)
                } else if draft.photoAction == "remove" {
                    draft.pendingPhoto = true
                    guard persist() else { return }
                    saved = try await source.removePhoto(saved, draft.photoRequest)
                }
                guard current, !Task.isCancelled else { return }
                onSaved(saved); finished = true; storage.clear()
                UINotificationFeedbackGenerator().notificationOccurred(.success); dismiss()
            } catch {
                guard current, !Task.isCancelled else { return }
                if WishFailure.isDefiniteRejection(error) {
                    draft.pendingMetadata = false; draft.pendingPhoto = false
                    draft.metadataRequest = UUID(); draft.photoRequest = UUID()
                    draft.fields.localizeNumbers(to: .current)
                }
                if let api = error as? APIError, api.status == 409 { conflict = true; draft.needsReview = true }
                self.error = WishFailure.message(error)
                _ = persist()
            }
        }
    }

    private func reload() {
        guard current, !saving else { return }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                let currentValues = try await source.list()
                guard current, let latest = currentValues.first(where: { $0.id == draft.id }) else {
                    error = "Este antojo ya no está en la lista compartida."; return
                }
                draft = WishEditorDraft(id: latest.id, fields: WishFields(latest), base: latest)
                photoData = nil; photoDirty = true; photoSelection = nil; conflict = false; error = nil
                onSaved(latest); _ = persist()
            } catch { if current { self.error = WishFailure.message(error) } }
        }
    }
}

struct WishCurrencyPicker: View {
    @Binding var selection: String?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private let frequent = ["MXN", "ARS", "USD", "BRL"]
    private var matches: [String] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return CoupleWishPrice.currencyCodes.sorted().filter {
            query.isEmpty || $0.localizedCaseInsensitiveContains(query) || name($0).localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        NavigationStack {
            List {
                if search.isEmpty { Section("A mano") { ForEach(frequent, id: \.self, content: row) } }
                Section("Todas las monedas") { ForEach(matches.filter { !search.isEmpty || !frequent.contains($0) }, id: \.self, content: row) }
            }.searchable(text: $search, prompt: "Código o nombre de la moneda")
                .navigationTitle("Elegir moneda").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
    }
    private func name(_ code: String) -> String { Locale.current.localizedString(forCurrencyCode: code)?.localizedCapitalized ?? code }
    private func row(_ code: String) -> some View {
        Button {
            selection = code; dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(code).font(.body.monospaced().weight(.semibold)).frame(width: 50, alignment: .leading)
                Text(name(code)).foregroundStyle(.primary)
                Spacer(minLength: 0)
                if selection == code { Image(systemName: "checkmark").accessibilityHidden(true) }
            }.frame(minHeight: 44)
        }.accessibilityIdentifier("wish.currency.\(code)").accessibilityAddTraits(selection == code ? .isSelected : [])
    }
}

private struct WishBrowserTarget: Identifiable { let id = UUID(); let url: URL }

struct WishWebLinkView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
