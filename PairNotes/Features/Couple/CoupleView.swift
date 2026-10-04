import SwiftUI
import UIKit
import AuthenticationServices
import PhotosUI
import PairNotesCore

struct CoupleView: View {
    @ObservedObject var services: AppServices
    let widgetMessage: String?
    let widgetConnecting: Bool
    let connectWidget: () async -> Void
    @State private var invitation: PairInvite?
    @State private var sheet: CoupleSheet?
    @State private var busy = false
    @State private var message: String?
    @State private var closingPair = false
    @State private var pairToClose: PairMembership?
    @State private var signingOut = false
    @State private var replacingInvite = false
    @State private var revokingInvite = false
    @State private var invitationExpired = true

    var body: some View {
        List {
            if let identity = services.identity {
                Section("Tu perfil") {
                    Button { sheet = .profile } label: {
                        HStack(spacing: 12) {
                            ProfileAvatarView(services: services, uid: identity.uid, name: identity.displayName,
                                              reference: services.profileAvatar)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(identity.displayName).foregroundStyle(.primary)
                                Text("Editar perfil").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }.padding(.vertical, 4)
                    }.accessibilityIdentifier("couple.editProfile")
                }
                if !services.membershipResolved {
                    Section { ProgressView("Consultando la pareja vinculada…") }
                } else if let pair = services.membership {
                    Section {
                        CouplePortraits(services: services)
                        HStack {
                            Label(pair.partner.displayName, systemImage: "heart.fill")
                            Spacer()
                            Menu {
                                Button("Desvincular pareja", systemImage: "person.crop.circle.badge.minus", role: .destructive) {
                                    pairToClose = pair
                                    closingPair = true
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }.buttonStyle(.borderless).accessibilityLabel("Opciones de pareja")
                        }
                    } header: { Text("Vinculados") } footer: {
                        Text("Los dibujos se comparten entre estas dos cuentas.")
                    }
                    Section("Su historia") {
                        NavigationLink { TogetherSettingsView(services: services) } label: {
                            Label("Juntos desde y avisos mensuales", systemImage: "calendar.badge.clock")
                        }
                        NavigationLink { DistanceSettingsView(services: services) } label: {
                            Label("Nuestra distancia", systemImage: "location.circle")
                        }
                        NavigationLink { MessagesView(services: services) } label: {
                            Label("Nuestros mensajes", systemImage: "bubble.left.and.text.bubble.right")
                        }
                    }
                    Section("Avisos de dibujos y mensajes") {
                        if services.notificationsEnabled {
                            Label("Notificaciones activadas", systemImage: "bell.badge")
                            Menu("Opciones de notificaciones", systemImage: "ellipsis.circle") {
                                Button("Desactivar avisos", systemImage: "bell.slash") {
                                    perform { try await services.disableNotifications() }
                                }
                            }
                        } else {
                            Button("Activar notificaciones", systemImage: "bell") {
                                perform {
                                    let granted = try await services.enableNotifications()
                                    message = granted ? "Avisos activados." : "Podés permitir las notificaciones de PairNotes desde Ajustes."
                                }
                            }
                        }
                        Text("Recibirás un aviso cuando tu pareja envíe un dibujo o mensaje. La notificación no incluye su contenido privado.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Sus widgets") {
                        Button("Conectar el widget", systemImage: "square.grid.2x2") {
                            Task { await connectWidget() }
                        }.disabled(widgetConnecting)
                        if widgetConnecting { ProgressView() }
                        Text(widgetMessage ?? "En inicio: «Último dibujo». En la pantalla de bloqueo: «Tu mensaje», «Juntos desde» y «Nuestra distancia». Mantené presionada la pantalla para agregarlos.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("La actualización depende de iOS. Abrí la app si el widget pide reconectar.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    invitationSection
                    Section {
                        Button("Tengo una invitación", systemImage: "text.badge.plus") { sheet = .acceptInvite }
                            .accessibilityIdentifier("couple.openInvitation")
                    } footer: {
                        Text("Podés pegar el código solo o el mensaje completo que te compartió tu pareja.")
                    }
                }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Un espacio para los dos").font(.title2.bold())
                        Text("Iniciá sesión para vincular sus cuentas y enviarse dibujos. Tus borradores locales se pueden usar desde Crear.")
                        AppleAccountButton { perform { try await services.signInApple(presentationAnchor: try presentationWindow()) } }
                            .frame(height: 46)
                        Button("Continuar con Google") {
                            perform { try await services.signInGoogle(presenting: try presentingController()) }
                        }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                    }.padding(.vertical, 8)
                }.disabled(!services.isConfigured)
                if let setup = services.setupMessage {
                    Section { Text(setup).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            if busy { Section { ProgressView("Procesando…") } }
            if let text = message ?? services.lastError {
                Section { Text(text).font(.footnote).accessibilityIdentifier("couple.status") }
            }
        }
        .disabled(busy)
        .navigationTitle("Nosotros")
        .toolbar {
            if services.identity != nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Editar perfil", systemImage: "pencil") { sheet = .profile }
                        Button("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            signingOut = true
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Opciones de cuenta")
                    .disabled(busy)
                }
            }
        }
        .sheet(item: $sheet) { route in
            switch route {
            case .profile:
                if let identity = services.identity {
                    ProfileEditor(services: services, identity: identity)
                }
            case .acceptInvite:
                AcceptInvitationView(services: services) {
                    invitation = nil
                    message = "Sus cuentas ya están vinculadas."
                }
            case .invitationCode:
                if let invitation {
                    InvitationCodeView(invitation: invitation)
                }
            }
        }
        .task(id: invitation?.expiresAt) {
            invitationExpired = invitation?.isExpired(at: Date()) ?? true
            guard let invitation, !invitationExpired else { return }
            do { try await Task.sleep(for: .seconds(max(0, invitation.expiresAt.timeIntervalSinceNow))) }
            catch { return }
            invitationExpired = true
        }
        .onChange(of: services.identity?.uid) { _, _ in
            invitation = nil
            sheet = nil
            message = nil
            signingOut = false
            closingPair = false
            pairToClose = nil
            replacingInvite = false
            revokingInvite = false
        }
        .onChange(of: services.membership) { _, pair in
            closingPair = false
            pairToClose = nil
            if pair != nil {
                invitation = nil
                if sheet != .profile { sheet = nil }
                replacingInvite = false
                revokingInvite = false
            }
        }
        .refreshable {
            guard let uid = services.identity?.uid, !busy else { return }
            do { try await services.refreshMembership() }
            catch {
                guard services.identity?.uid == uid else { return }
                message = error.localizedDescription
            }
        }
        .confirmationDialog("¿Crear otra invitación?", isPresented: $replacingInvite, titleVisibility: .visible) {
            Button("Crear otra invitación") { createInvite() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("El código anterior dejará de funcionar. Compartí la nueva invitación con tu pareja.")
        }
        .confirmationDialog("¿Revocar esta invitación?", isPresented: $revokingInvite, titleVisibility: .visible) {
            Button("Revocar invitación", role: .destructive) {
                perform { try await services.revokeInvite(); invitation = nil; message = "Invitación revocada." }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Tu pareja ya no podrá vincularse con este código.") }
        .confirmationDialog("¿Cerrar sesión en este iPhone?", isPresented: $signingOut, titleVisibility: .visible) {
            Button("Cerrar sesión", role: .destructive) { perform { try await services.signOut() } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Los envíos pendientes se cancelarán. Los borradores se conservan para esta cuenta en este iPhone.")
        }
        .confirmationDialog("¿Desvincular esta pareja?", isPresented: $closingPair, titleVisibility: .visible) {
            Button("Confirmar identidad y desvincular", role: .destructive) {
                let expectedPair = pairToClose
                perform {
                    guard let expectedPair else { return }
                    if services.authProvider == "apple" {
                        try await services.reauthenticateApple(presentationAnchor: try presentationWindow())
                    } else {
                        try await services.reauthenticateGoogle(presenting: try presentingController())
                    }
                    guard services.membership?.id == expectedPair.id,
                          services.membership?.pairEpoch == expectedPair.pairEpoch else {
                        throw ServiceError.sessionChanged
                    }
                    try await services.closePair()
                    invitation = nil
                    message = "La pareja se desvinculó."
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se cerrará el acceso compartido a los dibujos, se desconectará el widget y se cancelarán los envíos pendientes. Confirmá tu identidad para continuar.")
        }
    }

    private var invitationSection: some View {
        Section {
            if let invitation {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(invitationExpired ? "Invitación vencida" : "Invitación lista",
                              systemImage: invitationExpired ? "clock.badge.exclamationmark" : "envelope.badge")
                        Text(invitationExpired ? "Creá otra para vincular sus cuentas." : "Vence a las \(invitation.expiresAt.formatted(date: .omitted, time: .shortened))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Ver código", systemImage: "text.viewfinder") { sheet = .invitationCode }
                            .disabled(invitationExpired)
                        Divider()
                        Button("Crear otra invitación", systemImage: "arrow.clockwise") { replacingInvite = true }
                        Button("Revocar invitación", systemImage: "xmark.circle", role: .destructive) { revokingInvite = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .buttonStyle(.borderless).accessibilityLabel("Opciones de invitación")
                }.padding(.vertical, 4)
                // Separate rows and an explicit style keep List from combining row actions.
                ShareLink(item: invitation.shareMessage) {
                    Label("Compartir invitación", systemImage: "square.and.arrow.up")
                }.buttonStyle(.borderless)
                    .disabled(invitationExpired)
                    .accessibilityIdentifier("couple.shareInvitation")
                Button("Copiar código", systemImage: "doc.on.doc") { copyInvite(invitation) }
                    .buttonStyle(.borderless)
                    .disabled(invitationExpired)
                    .accessibilityIdentifier("couple.copyInvitation")
            } else {
                Button("Crear invitación", systemImage: "person.badge.plus") { createInvite() }
                    .accessibilityIdentifier("couple.createInvitation")
            }
        } header: { Text("Invitá a tu pareja") } footer: {
            Text("Compartí la invitación sólo con tu pareja. Cada código se puede usar una sola vez.")
        }
    }

    private func copyInvite(_ value: PairInvite) {
        guard value == invitation, !value.isExpired(at: Date()), services.membership == nil else {
            message = "La invitación ya no está disponible. Creá una nueva."
            return
        }
        copyInvitationCode(value)
        message = "Código copiado."
    }

    private func createInvite() {
        let uid = services.identity?.uid
        perform {
            let value = try await services.createInvite()
            guard services.identity?.uid == uid, services.membershipResolved, services.membership == nil else { return }
            invitationExpired = value.isExpired(at: Date())
            invitation = value
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        let uid = services.identity?.uid
        busy = true
        message = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() }
            catch is CancellationError { return }
            catch {
                guard uid == nil || services.identity?.uid == uid else { return }
                message = error.localizedDescription
            }
        }
    }

    private func presentationWindow() throws -> UIWindow {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow) else {
            throw ServiceError.authorizationInProgress
        }
        return window
    }

    private func presentingController() throws -> UIViewController {
        guard var controller = try presentationWindow().rootViewController else { throw ServiceError.authorizationInProgress }
        while let presented = controller.presentedViewController { controller = presented }
        return controller
    }
}

private enum CoupleSheet: String, Identifiable {
    case profile, acceptInvite, invitationCode
    var id: String { rawValue }
}

private struct ProfileEditor: View {
    @ObservedObject var services: AppServices
    let identity: SessionIdentity
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var discarding = false
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var removePhoto = false
    @State private var loadingPhoto = false
    @State private var crop: SelectedPhotoCrop?
    @FocusState private var nameFocused: Bool

    init(services: AppServices, identity: SessionIdentity) {
        self.services = services
        self.identity = identity
        _name = State(initialValue: identity.displayName)
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasChanges: Bool { cleanName != identity.displayName || photoData != nil || removePhoto }
    private var canSave: Bool { !saving && !loadingPhoto && hasChanges && (1...60).contains(cleanName.utf16.count) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        if let photoData, let image = UIImage(data: photoData) {
                            Image(uiImage: image).resizable().scaledToFill().frame(width: 100, height: 100).clipShape(Circle())
                        } else {
                            ProfileAvatarView(services: services, uid: identity.uid, name: cleanName,
                                reference: removePhoto ? nil : services.profileAvatar, size: 100)
                        }
                        Spacer()
                    }.listRowBackground(Color.clear)
                    PhotosPicker(selection: $photoItem, matching: .images) { Label("Elegir foto", systemImage: "photo") }
                    if photoData != nil || (services.profileAvatar != nil && !removePhoto) {
                        Button("Quitar foto", systemImage: "trash", role: .destructive) { photoData = nil; removePhoto = true }
                    }
                    if loadingPhoto { ProgressView("Preparando foto…") }
                } footer: { Text("Tu foto será visible sólo para tu pareja y en sus widgets.") }
                Section {
                    TextField("Tu nombre", text: $name)
                        .textContentType(.nickname).textInputAutocapitalization(.words)
                        .focused($nameFocused).submitLabel(.done).onSubmit { save() }
                        .accessibilityIdentifier("couple.profileName")
                } header: { Text("Nombre") } footer: {
                    Text("Así te verá tu pareja. Hasta 60 caracteres.")
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
                if saving { Section { ProgressView("Guardando…") } }
            }
            .disabled(saving)
            .navigationTitle("Editar perfil").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { if hasChanges { discarding = true } else { dismiss() } }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { save() }.disabled(!canSave).accessibilityIdentifier("couple.saveProfile")
                }
            }
            .confirmationDialog("¿Descartar los cambios?", isPresented: $discarding, titleVisibility: .visible) {
                Button("Descartar cambios", role: .destructive) { dismiss() }
                Button("Seguir editando", role: .cancel) {}
            }
            .interactiveDismissDisabled(saving || hasChanges)
            .sheet(item: $crop) { selection in
                PhotoCropEditor(image: selection.image, onCancel: { crop = nil }, onConfirm: { image in
                    photoData = image.jpegData(compressionQuality: 0.85)
                    removePhoto = false
                    crop = nil
                })
            }
            .task(id: photoItem) {
                guard let photoItem else { return }
                loadingPhoto = true
                defer { if self.photoItem == photoItem { loadingPhoto = false } }
                do {
                    guard let bytes = try await photoItem.loadTransferable(type: Data.self), !Task.isCancelled, self.photoItem == photoItem,
                          let image = UIImage(data: try SelectedPhoto.jpeg(bytes, maximum: 800)) else { return }
                    crop = SelectedPhotoCrop(image: image)
                } catch { errorMessage = "No se pudo abrir esta foto. Elegí otra imagen." }
            }
        }
    }

    private func save() {
        guard canSave, services.identity?.uid == identity.uid else { return }
        let value = cleanName
        saving = true
        errorMessage = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                try await services.updateProfile(name: value, photo: photoData, removePhoto: removePhoto)
                guard services.identity?.uid == identity.uid else { return }
                dismiss()
            } catch is CancellationError { return }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct AcceptInvitationView: View {
    @ObservedObject var services: AppServices
    let onAccepted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var linking = false
    @State private var errorMessage: String?

    private var code: String? { InvitationCode.parse(input) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Pegá el código o el mensaje completo", text: $input, axis: .vertical)
                        .lineLimit(3...8).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .privacySensitive().accessibilityIdentifier("couple.invitationInput")
                    HStack {
                        PasteButton(payloadType: String.self) { values in input = values.joined(separator: "\n") }
                            .labelStyle(.titleAndIcon)
                        Spacer()
                        if !input.isEmpty { Button("Borrar", systemImage: "xmark.circle") { input = "" }.buttonStyle(.borderless) }
                    }
                } header: { Text("Invitación de tu pareja") } footer: {
                    Text("Copiá el mensaje de WhatsApp y pegalo acá. También sirve el código solo.")
                }
                if code != nil {
                    Section {
                        Label("Código listo para usar", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                        Text("Al tocar Vincular, las dos cuentas podrán compartir dibujos.").font(.footnote)
                    }
                } else if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section { Text("No pudimos reconocer un único código. Pegá el código solo o el mensaje completo de PairNotes.").font(.footnote).foregroundStyle(.secondary) }
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
                if linking { Section { ProgressView("Vinculando cuentas…") } }
            }
            .disabled(linking)
            .navigationTitle("Tengo una invitación").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() }.disabled(linking) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Vincular") { accept() }.disabled(linking || code == nil)
                        .accessibilityIdentifier("couple.acceptInvitation")
                }
            }
            .interactiveDismissDisabled(linking)
            .onChange(of: input) { _, _ in errorMessage = nil }
        }
    }

    private func accept() {
        guard !linking, let code, let uid = services.identity?.uid, services.membership == nil else { return }
        linking = true
        errorMessage = nil
        Task { @MainActor in
            defer { linking = false }
            do {
                try await services.acceptInvite(token: code)
                guard services.identity?.uid == uid else { return }
                onAccepted()
                dismiss()
            } catch is CancellationError { return }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct InvitationCodeView: View {
    let invitation: PairInvite
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    if invitation.isExpired(at: timeline.date) {
                        Text("La invitación venció. Creá una nueva desde Nosotros.")
                    } else {
                        Text(invitation.token).font(.body.monospaced()).textSelection(.enabled).privacySensitive()
                        Button(copied ? "Código copiado" : "Copiar código", systemImage: "doc.on.doc") {
                            guard !invitation.isExpired(at: Date()) else { return }
                            copyInvitationCode(invitation)
                            copied = true
                        }.buttonStyle(.borderless)
                    }
                }
            }
            .navigationTitle("Código de invitación").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
        }
    }
}

@MainActor
private func copyInvitationCode(_ invitation: PairInvite) {
    // Only an explicit tap writes to the clipboard; never read it automatically.
    UIPasteboard.general.setItems([["public.utf8-plain-text": invitation.token]],
                                 options: [.expirationDate: invitation.expiresAt])
}

private struct AppleAccountButton: UIViewRepresentable {
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: .continue, authorizationButtonStyle: .black)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        return button
    }
    func updateUIView(_ uiView: ASAuthorizationAppleIDButton, context: Context) { context.coordinator.action = action }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tap() { action() }
    }
}
