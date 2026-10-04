import SwiftUI
import UIKit
import AuthenticationServices
import PairNotesCore

struct CoupleView: View {
    @ObservedObject var services: AppServices
    let widgetMessage: String?
    let widgetConnecting: Bool
    let connectWidget: () async -> Void
    @State private var name = ""
    @State private var invitation: PairInvite?
    @State private var invitationCode = ""
    @State private var busy = false
    @State private var message: String?
    @State private var closingPair = false
    @State private var signingOut = false

    var body: some View {
        List {
            if let identity = services.identity {
                Section("Tu perfil") {
                    TextField("Tu nombre", text: $name).textContentType(.nickname)
                    Button("Guardar nombre") {
                        perform { try await services.updateDisplayName(name); message = "Nombre actualizado." }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text(identity.displayName).font(.caption).foregroundStyle(.secondary)
                }
                if !services.membershipResolved {
                    Section { ProgressView("Consultando la pareja vinculada…") }
                } else if let pair = services.membership {
                    Section("Vinculados") {
                        Label(pair.partner.displayName, systemImage: "heart.fill")
                        Text("Los dibujos se comparten entre estas dos cuentas.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Desvincular pareja", role: .destructive) { closingPair = true }
                    }
                    Section("Avisos de dibujos nuevos") {
                        if services.notificationsEnabled {
                            Label("Notificaciones activadas", systemImage: "bell.badge")
                            Button("Desactivar avisos") {
                                perform { try await services.disableNotifications() }
                            }
                        } else {
                            Button("Activar notificaciones", systemImage: "bell") {
                                perform {
                                    let granted = try await services.enableNotifications()
                                    message = granted ? "Avisos activados." : "Podés permitir las notificaciones de PairNotes desde Ajustes."
                                }
                            }
                        }
                        Text("Recibirás un aviso cuando tu pareja envíe un dibujo. El mensaje no incluye el contenido privado de la nota.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Dibujo en inicio") {
                        Button("Conectar el widget", systemImage: "square.grid.2x2") {
                            Task { await connectWidget() }
                        }.disabled(widgetConnecting)
                        if widgetConnecting { ProgressView() }
                        Text(widgetMessage ?? "Agregá el widget «Último dibujo» desde la pantalla de inicio. Muestra el último dibujo recibido; todos siguen disponibles en Recuerdos.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("La actualización depende de iOS. Abrí la app si el widget pide reconectar.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section("Invitá a tu pareja") {
                        if let invitation {
                            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                if invitation.isExpired(at: timeline.date) {
                                    Text("La invitación venció. Creá una nueva.").foregroundStyle(.secondary)
                                } else {
                                    Text(invitation.token).font(.callout.monospaced()).textSelection(.enabled)
                                    Text("Vence \(invitation.expiresAt.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    ShareLink(item: invitation.token, subject: Text("Nuestra invitación de PairNotes"),
                                              message: Text("Pegá este código en Nosotros para vincular nuestras cuentas.")) {
                                        Label("Compartir invitación", systemImage: "square.and.arrow.up")
                                    }
                                }
                            }
                            Button("Revocar invitación") {
                                perform { try await services.revokeInvite(); self.invitation = nil }
                            }
                        }
                        Button(invitation == nil ? "Crear invitación" : "Crear otra invitación") {
                            perform { invitation = try await services.createInvite() }
                        }
                        Text("Compartí el código sólo con tu pareja. Al usarlo, las dos cuentas quedan vinculadas.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Tengo una invitación") {
                        TextField("Pegá el código", text: $invitationCode)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Vincular cuentas") {
                            perform {
                                try await services.acceptInvite(token: invitationCode)
                                invitationCode = ""
                                invitation = nil
                            }
                        }.disabled(invitationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section("Cuenta") {
                    Button("Cerrar sesión", role: .destructive) { signingOut = true }
                    Text("La ubicación está desactivada. Podés compartir dibujos sin compartir tu posición.")
                        .font(.footnote).foregroundStyle(.secondary)
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
        .task { name = services.identity?.displayName ?? "" }
        .onChange(of: services.identity?.uid) { _, _ in
            name = services.identity?.displayName ?? ""
            invitation = nil
            invitationCode = ""
            message = nil
        }
        .refreshable {
            guard services.identity != nil else { return }
            do { try await services.refreshMembership() } catch { message = error.localizedDescription }
        }
        .confirmationDialog("¿Cerrar sesión en este iPhone?", isPresented: $signingOut, titleVisibility: .visible) {
            Button("Cerrar sesión", role: .destructive) { perform { try await services.signOut() } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Los envíos pendientes se cancelarán. Los borradores se conservan para esta cuenta en este iPhone.")
        }
        .confirmationDialog("¿Desvincular esta pareja?", isPresented: $closingPair, titleVisibility: .visible) {
            Button("Confirmar identidad y desvincular", role: .destructive) {
                perform {
                    if services.authProvider == "apple" {
                        try await services.reauthenticateApple(presentationAnchor: try presentationWindow())
                    } else {
                        try await services.reauthenticateGoogle(presenting: try presentingController())
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

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        message = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() }
            catch is CancellationError { return }
            catch { message = error.localizedDescription }
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
