# PairNotes · M0 y base de M1

App iOS nativa en preparación, basada en [el plan recibido](Plan_app_pareja_Swift.md). Trabajamos desde Linux y usamos runners macOS de GitHub Actions para compilar iOS. Repositorio privado: [Niiihuel/pairnotes](https://github.com/Niiihuel/pairnotes). [El flujo de CI](docs/CI_GITHUB_ACTIONS.md) registra las ejecuciones reales, sus artefactos y límites.

El alcance incluye cuatro pestañas con datos ficticios, un experimento PaperKit para texto/imagen/trazo, guardado explícito de un borrador local, render y una extensión de widget local. El experimento conserva un único borrador. No hay autenticación, pareja real, publicación, servidor, seguimiento de ubicación ni motor Studio.

**CI aprobada:** [run 37222564964](https://github.com/Niiihuel/pairnotes/actions/runs/37222564964), commit `7c60f87`: 15 tests Swift y 15 Python en Linux, compilación de app/widget con SDK 26.0 y 2 tests PaperKit en simulador iOS 26.2. [Evidencia visual](docs/evidence/m0/README.md). Firma, widget visible y validación interactiva en dispositivos continúan pendientes.

## Estructura

- `PairNotes.xcodeproj`: proyecto listo para abrir, con scheme compartido `PairNotes`.
- `PairNotes/App` y `Features`: SwiftUI y mocks inyectados.
- `PairNotes/Core`: modelos Foundation, contratos, mocks y almacenamiento atómico; módulo `PairNotesCore`, compartido con SwiftPM.
- `PairNotes/Canvas/NativePaper`: experimento iOS 26 de composición, fuente editable y renders.
- `PairNotes/Widgets`: extensión separada y resolución del contenedor compartido.
- `PairNotes/Tests`: tests portables y tests PaperKit ejecutados en el simulador de CI.
- `Config`: ejemplos sin credenciales ni identificadores registrados.
- [Validación inicial](docs/VALIDACION_INICIAL.md): entorno, resultados reales, limitaciones y próximo corte.
- [Referencias verificadas](docs/REFERENCIAS_M0.md): firmas Apple y disponibilidad.

## Pruebas portables

Con una distribución completa de Swift 5.10 o posterior:

```bash
swift test
```

En este NixOS, el paquete Swift 5.10 compila los fuentes pero SwiftPM no logra ejecutar el descubrimiento de tests por una biblioteca ausente. La alternativa es el contenedor oficial Swift:

```bash
docker run --rm \
  -v "$PWD:/workspace:ro" -w /workspace \
  swift:6.2 swift test --scratch-path /tmp/pairnotes-build
```

Esos tests no importan PaperKit, SwiftUI ni WidgetKit. Comprueban bytes opacos, persistencia, revisiones y mocks; no equivalen a probar el editor iOS.

## Abrir y validar en un Mac

No hace falta un Mac propio para la compilación automática: `.github/workflows/ci.yml` ejecuta los comandos en GitHub Actions. Esta sección también sirve para un Mac remoto o local cuando esté disponible.

1. Instalar Xcode con SDK iOS 26 o posterior y un runtime de simulador compatible. Registrar las versiones efectivamente usadas.
2. Abrir `PairNotes.xcodeproj`, seleccionar scheme `PairNotes` y un iPhone con iOS 26 o posterior.
3. Compilar primero sin firma para simulador:

```bash
xcodebuild -version
xcodebuild -showsdks
xcrun simctl list devices available
xcodebuild -project PairNotes.xcodeproj -scheme PairNotes \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

Para ejecutar los tests nativos, reemplazar `UDID_DEL_SIMULADOR` por uno del listado real:

```bash
xcodebuild -project PairNotes.xcodeproj -scheme PairNotes \
  -destination 'platform=iOS Simulator,id=UDID_DEL_SIMULADOR' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

Estos comandos requieren Mac; GitHub Actions registra la compilación con SDK 26.0 y la ejecución en runtime 26.2. Ejecutar en runtime 26.0 exacto sigue pendiente. Una compilación con SDK 27 no reemplaza el ensayo del mínimo.

## Icono de la app

Se conserva [icon.png](icon.png), proporcionado por el usuario. El catálogo `PairNotes/App/Assets.xcassets` contiene su adaptación de 1024 × 1024 RGB, con fondo oscuro `#111118` elegido por el usuario, sin cambiar el diseño ni redondear esquinas manualmente. Pertenece sólo al target de la app. Para reproducir la conversión con ImageMagick:

```bash
magick icon.png -background '#111118' -alpha remove -alpha off \
  -resize 1024x1024 -strip \
  PNG24:PairNotes/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```

## Prueba del editor y widget local

En **Crear**, el ejemplo contiene texto, una ilustración sintética y un trazo. Se puede dibujar con el dedo, seleccionar objetos, agregar texto desde la paleta y elegir una foto mediante PhotosPicker. La app no pide acceso general a la fototeca. **Guardar y renderizar** captura una revisión y guarda fuente más tres imágenes; **Reabrir** restaura el borrador. Cerrar y volver a abrir verifica persistencia real. El editor no tiene autosave en este corte.

Para compartir el render con el widget se necesita configuración propia:

1. Copiar `Config/Local.xcconfig.example` a `Config/Local.xcconfig` y completar Team ID, bundle ID y App Group existentes y autorizados.
2. Con la cuenta Apple del usuario, habilitar ese mismo App Group en la app y extensión y comprobar el provisioning. El código no registra capacidades por su cuenta.
3. Copiar `Config/AppGroup.entitlements.example` a `Config/App.local.entitlements` y `Config/Widget.local.entitlements`. Activar sus rutas en `Local.xcconfig`.
4. Compilar, ejecutar y guardar una revisión. Agregar manualmente el widget **PairNotes · prueba local** desde iOS. Tocar el widget abre Crear.

Sin App Group la app sigue guardando localmente y el widget muestra un estado vacío explícito. `reloadTimelines` es una solicitud al sistema; no asegura actualización inmediata. El widget no usa red ni marca notas como vistas.

Los archivos locales de configuración, claves APNs, certificados y `GoogleService-Info.plist` están ignorados por Git. Los IDs `org.example` son marcadores para build local, no cuentas o permisos concedidos. No hay configuración Firebase en este corte.

## Regenerar el proyecto, sólo si hace falta

El `.xcodeproj` ya está incluido. Ruby sólo se necesita para regenerarlo después de agregar archivos, no para abrirlo ni compilarlo:

```bash
bundle install --gemfile scripts/Gemfile
BUNDLE_GEMFILE=scripts/Gemfile bundle exec ruby scripts/generate_project.rb --replace
```

`--replace` sobrescribe la configuración generada: revisar antes cambios manuales de Xcode. Conservar firma y valores propios en `Config/Local.xcconfig`.
