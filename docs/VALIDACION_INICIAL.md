# Validación inicial · PairNotes

Fecha: 4 de octubre de 2026. Alcance autorizado: M0 y base necesaria de M1.

**Continuación posterior:** el usuario autorizó avanzar con envío, historial, avisos y widget recibido, y reemplazar Firebase por Railway. Ver [la enmienda](RAILWAY_Y_FLUJO_NOTAS.md) y [los resultados de ese corte](VALIDACION_RAILWAY.md). El contenido restante conserva el registro histórico de M0; no describe el estado actual de la app.

Continuación autorizada: el usuario eligió trabajar sin Mac propio, compilar mediante GitHub Actions, crear el repositorio en `Niiihuel` y continuar luego por fases verificadas. Se creó el repositorio privado [Niiihuel/pairnotes](https://github.com/Niiihuel/pairnotes). El usuario también aportó `icon.png` y eligió fondo oscuro para su adaptación a icono iOS. La evidencia actualizada está en [CI_GITHUB_ACTIONS.md](CI_GITHUB_ACTIONS.md). El resto de este documento conserva el registro histórico de la inspección inicial; los 36 archivos enumerados al final corresponden a esa primera entrega.

**Resultado de la primera entrega:** base portable y proyecto iOS preparados; en ese momento compilación y ejecución Apple estaban pendientes. Después se compiló realmente con SDK iOS 26.0 en GitHub Actions y se ejecutaron pruebas PaperKit en simulador 26.2. Consultar el estado de cada prueba y sus correcciones en el registro de CI enlazado arriba. La validación interactiva en iPhone, App Group y widget visible sigue pendiente.

**Actualización final de CI:** la [ejecución 37222564964](https://github.com/Niiihuel/pairnotes/actions/runs/37222564964), commit `7c60f87`, aprobó compilación mínima con icono, 15 tests Swift portables, 15 tests Python y los 2 tests nativos. El roundtrip conserva texto indexable, imagen y trazo; su segunda restauración tiene render idéntico a la primera. Se inspeccionaron y conservaron los tres PNG reales en [evidence/m0](evidence/m0/README.md). Los pendientes enumerados debajo son el registro inicial: compilación SDK 26.0 y pruebas automatizadas sobre runtime 26.2 ya están resueltos; no lo están interacción manual, runtime 26.0 en ejecución ni validación física/servicios.

## Inspección y documentación recibida

La carpeta `/home/nihuel/projects/personal/dnnote` contenía únicamente `Plan_app_pareja_Swift.md` (43 KB). No había aplicación, proyecto Xcode, `Package.swift`, servidor ni repositorio Git inicializado. Se leyó el plan completo y `/home/nihuel/.codex/RTK.md`, referenciado por las instrucciones del usuario.

No estaban `AGENTS.md`, `PLAN_COMPLETO.md`, `ARQUITECTURA_Y_CONTRATOS.md`, `DESIGN.md`, `BACKLOG_CODEX.md`, `PRUEBAS_Y_RELEASE.md` ni `FUENTES.md`. El usuario confirmó explícitamente usar el plan disponible para este corte. No se reconstruyeron esos documentos como si fueran originales. El plan recibido se conserva sin modificaciones. Los contratos locales son provisionales hasta contrastarlos con el paquete completo, si aparece.

## Entorno real

- Sistema: NixOS/Linux x86_64, kernel `7.1.3`; no es macOS.
- `swift`, `xcodebuild`, `xcrun`, `clang` y `xcodegen` no estaban en el PATH inicial.
- No hay SDK Apple, simulador iOS, firma, Team ID ni dispositivos iPhone disponibles desde este entorno.
- Nix y Docker disponibles; Docker server `29.6.0`.
- Nix ofrece Swift `5.10.1`, target `x86_64-pc-linux-gnu`. Foundation y XCTest requieren los paquetes correspondientes. SwiftPM Nix presentó fallos de bibliotecas al intentar descubrir tests, detallados debajo.
- Se usó Ruby `3.4.9` y la biblioteca `xcodeproj 1.27.0`, instalada en `/tmp/pairnotes-gems`, para crear y volver a leer el proyecto. No se instaló Xcode ni se cambió configuración de servicios.

La [tabla oficial de Xcode](https://developer.apple.com/xcode/system-requirements) consultada enumera SDKs 26 y 27. Eso acredita disponibilidad publicada, no instalación local. La prueba mínima deberá usar SDK/runtime iOS 26; las mejoras 27 están fuera del corte.

## Decisiones verificadas y límites

**Targets.** App `PairNotes`, extensión `PairNotesWidgets`, framework estático `PairNotesCore` y tests nativos `PairNotesNativeTests`. SwiftPM usa los mismos fuentes del core para Linux. Deployment target 26.0; lenguaje Swift 5, tools 5.10 para el paquete portable. La estructura del proyecto se verificó con un parser; el typecheck de frameworks Apple requiere Mac.

**Editor.** Adaptador UIKit/SwiftUI de `PaperMarkupViewController`; funciones restringidas a `FeatureSet.version1` y SDR. `PaperMarkup` conserva texto, imagen y dibujo en bytes nativos y permite render asíncrono. Se verificaron firmas y disponibilidad en fuentes Apple; ver [referencias](REFERENCIAS_M0.md). La selección por dedo se configura explícitamente para que la preferencia del sistema no anule el toggle de selección.

El experimento usa un único borrador ficticio inicial de 1536 × 1536. Permite texto con la interfaz nativa, imagen sintética, dibujo con dedo y foto seleccionada por el usuario. PhotosPicker obtiene sólo la selección; ImageIO reduce la foto, aplica orientación y entrega píxeles, sin copiar EXIF a la fuente. La comprobación visual de orientación y metadatos sigue pendiente en iOS.

**Persistencia.** El dominio depende sólo de Foundation. `NoteDocument` separa versión de esquema, motor, versión mínima, lienzo, activos y hash de fuente. Las publicaciones son valores inmutables; las notas ficticias de UI son otro tipo. No se implementa publicación. El actor local guarda un sobre JSON atómico `.pairnote` con fuente nativa y derivados; mantiene revisiones monotónicas y rechaza sobrescritura de documentos incompatibles/corruptos. Se conserva el render para lectura de versiones futuras compatibles con el sobre conocido.

Este sobre con `Data` codificado como Base64 es un formato **local del experimento**, no un documento Firestore. Permite verificar coherencia sin introducir aún SwiftData, catálogo multiborrador o una transacción entre muchos archivos. El índice SwiftData y la separación física de binarios pertenecen al editor de producción posterior. El store asume un único actor escritor por directorio; el widget sólo lee su snapshot.

**Render.** Una captura inmutable produce fuente, PNG final 1536, widget 1024 y miniatura 384, en contexto sRGB de 8 bits con fondo blanco. Se bloquea interacción durante guardado. El hash SHA-256 comprueba integridad y la misma revisión en fuente/derivados; no demuestra equivalencia visual ni autoriza acceso. La implementación portable del digest es local, con vectores conocidos en tests; no se usa para credenciales, firmas ni seguridad de servidor.

**Widget.** Extensión local pequeña/mediana, snapshot atómico con imagen, lectura independiente y deep link a Crear. No incluye red, Firestore, GPS, push, sesiones de widget ni widget de distancia. El contenedor exige App Group configurado legítimamente en ambos targets. Sin él se muestra estado vacío; no se sustituye por una carpeta privada fingiendo que es compartida. Escribir el snapshot y pedir `reloadTimelines` no garantiza la hora de presentación.

**Mocks y permisos.** Inicio, Crear, Recuerdos y Nosotros muestran datos ficticios identificados. No se solicita ubicación, no se crea `CLLocationManager`, no hay modos de fondo ni entitlements de ubicación. Google/Apple/Firebase siguen siendo la arquitectura futura; no se simula autenticación exitosa ni una pareja real. Studio sólo está reservado como identificador de formato, sin motor raster.

## Ejecuciones y evidencia

Inspección realizada con `pwd`, lectura de RTK y del plan, `rg --files --hidden`, `ls -la`, `git status --short --branch`, `uname -a`, `command -v` y consultas a Nix/Docker. `git status` devolvió “Not a git repository”; no se creó un historial ni se sobrescribió trabajo existente. Después de leer RTK, los comandos de shell se ejecutaron con su prefijo.

Documentación Apple consultada vía web y `curl -fsSL` sobre documentación Markdown oficial: APIs de PaperKit/PencilKit, PhotosPicker, WidgetKit y requisitos Xcode. El inventario y enlaces precisos están en `REFERENCIAS_M0.md`.

Comandos relevantes ejecutados:

```text
rtk nix eval --raw nixpkgs#swift.version
rtk nix shell nixpkgs#swift -c swift --version
rtk nix shell nixpkgs#swift -c swift -e 'import Foundation; print("Foundation OK")'
rtk nix-shell -p swift swiftpm swiftPackages.Foundation swiftPackages.XCTest --run ...
rtk nix shell nixpkgs#ruby -c gem install xcodeproj --version 1.27.0 --install-dir /tmp/pairnotes-gems --no-document
rtk env GEM_HOME=/tmp/pairnotes-gems GEM_PATH=/tmp/pairnotes-gems nix shell nixpkgs#ruby -c ruby scripts/generate_project.rb
rtk env GEM_HOME=/tmp/pairnotes-gems GEM_PATH=/tmp/pairnotes-gems nix shell nixpkgs#ruby -c bundle lock --gemfile scripts/Gemfile --local
rtk nix shell nixpkgs#swift -c swiftc -frontend -parse <cada archivo iOS>
```

- Swift aislado no encontró Foundation; el shell con Foundation/XCTest sí ejecutó `Foundation OK`.
- SwiftPM Nix necesitó resolver `libdispatch.so`; luego compiló core y tests, pero el descubrimiento de pruebas falló por `libIndexStore.so` ausente. `--disable-index-store` no resolvió ese fallo. No se contabiliza como tests aprobados.
- Generación del `.xcodeproj`: exit 0. Lectura con `xcodeproj` y REXML: 24 comprobaciones estructurales aprobadas, incluyendo pertenencia de archivos, extensión embebida, framework estático, test host y referencias del scheme. Esto no equivale a `xcodebuild`.
- Parse de sintaxis de los 13 archivos Swift de app, adaptador, widget y tests nativos: exit 0 con Swift 5.10. No resolvió imports ni verificó tipos de SDK Apple.
- Los dos Info.plist y el ejemplo de entitlements se leyeron correctamente con `plistlib` de Python. No acredita capabilities ni firma.

Los resultados de la suite portable se registran al final de este documento.

## Validación iOS pendiente: procedimiento de aceptación

Los comandos reproducibles de build/test y configuración están en [README](../README.md). Todos los siguientes puntos están **pendientes**, sin resultados simulados:

1. En Mac, registrar `xcodebuild -version`, `-showsdks` y runtimes de `simctl`. Compilar app, core, extensión y tests con SDK 26. Repetir en SDK posterior sólo como comprobación adicional.
2. Ejecutar `PaperRoundTripTests`: serializar/restaurar composición mixta, rechazar fuente corrupta, comparar píxeles y presencia en regiones de texto/imagen/trazo. Los tests están escritos, no ejecutados. Inspeccionar orientación, color y legibilidad del render frente al canvas; el roundtrip por sí solo puede conservar un error sistemático.
3. En iPhone/simulador, editar texto, insertar foto asimétrica, dibujar con dedo, seleccionar y transformar. Guardar, terminar proceso y reabrir. Confirmar fuente editable y misma revisión en PNG final, miniatura y widget. Confirmar que una versión incompatible sólo muestra su imagen y no se sobrescribe.
4. Configurar App Group y firma propios. Agregar el widget manualmente, guardar otra revisión y observar imagen/deep link. Probar snapshot ausente, corrupto y app cerrada. Registrar demoras reales; no exigir actualización instantánea.
5. Validar Dynamic Type, VoiceOver, paleta, popovers en iPhone/iPad y retorno desde otras pestañas. Medir memoria/latencia de serialización y tres renders; todavía no hay presupuesto medido.
6. Para cerrar la investigación de riesgo M0, usar dos iPhones físicos y configuración de desarrollo autorizada para comprobar el mecanismo push específico de WidgetKit, renovación de token, presupuestos, pantalla bloqueada, app terminada y red intermitente. Este corte no implementa servidor/push ni solicita esas credenciales. APNs aceptado no acredita widget visible.

No ejecutados por falta de entorno: compilación/link iOS, tests PaperKit, simulador, firma, App Group real, instalación física, widgets visibles, APNs, consumo y accesibilidad. Las pruebas de reglas Firebase, Google/Apple, invitaciones, distancia y permisos corresponden a hitos posteriores; no se añadieron servicios para adelantarlos.

## Archivos y siguiente corte

Se agregaron `README.md`, `.gitignore`, `Package.swift`, `PairNotes.xcodeproj`, `Config`, `scripts`, los fuentes de `PairNotes` y documentación en `docs`. No se modificó el plan original. La lista completa de archivos nuevos se registra al final.

**Siguiente corte propuesto, sin implementar:** cerrar M0 y la base de M1 en macOS con el SDK mínimo, corregir los errores reales que arroje Xcode, ejecutar el roundtrip y la inspección visual, configurar un App Group de desarrollo y verificar el widget local. Registrar resultados y riesgos pendientes de push en dos teléfonos. Con esa evidencia, definir el corte M2 de identidad Google/Apple y vinculación segura, incluyendo tests negativos de invitaciones, pertenencia y tercer usuario. No avanzar a M3 ni al motor Studio en esa tarea.

## Resultado final de tests portables

Se ejecutó realmente:

```bash
rtk docker run --rm --user "$(rtk id -u):$(rtk id -g)" \
  -v "$PWD:/workspace" -w /workspace \
  swift:6.2 swift test --scratch-path /tmp/pairnotes-build
rtk docker run --rm swift:6.2 swift --version
```

La imagen resolvió a Swift **6.2.4**, target `x86_64-unknown-linux-gnu`, digest `sha256:eccc7a97f9b9881d9659e2e788081fd7675f86d39793b51200bfb178398b3784`. Build finalizada en 6,79 s. **15 XCTest ejecutados, 0 fallos**: 9 de borradores y 6 de snapshots/mocks. XCTest informó 0,038 s; estos tiempos del fixture no miden rendimiento del editor. El mensaje adicional “0 tests” de Swift Testing corresponde a otro runner; la suite usa XCTest.

Cobertura observada: bytes opacos más los tres derivados tras reabrir; rechazo de revisiones viejas/duplicadas y tareas concurrentes fuera de orden; comprobación de revisión después de recrear el store; archivos ausentes/corruptos; esquemas, versiones y motores futuros en lectura; renders de revisiones mezcladas o faltantes; fuente manipulada; vectores SHA-256 conocidos; escritor y lector de widget independientes; snapshots duplicados y atrasados; corrupción/esquema futuro del snapshot; mocks ficticios y ubicación sin solicitar.

Los **2 tests nativos** de `PaperRoundTripTests` no se ejecutaron. Los fixtures portables son bytes sintéticos y no se presentan como documentos PaperKit ni imágenes PNG validadas. Decodificar PNG, comprobar semántica del editor y mostrar un widget pertenece a la validación iOS pendiente.

## Inventario de archivos nuevos

No se modificó `Plan_app_pareja_Swift.md`. Se agregaron:

```text
.gitignore
README.md
Package.swift
Config/App-Info.plist
Config/Widget-Info.plist
Config/Base.xcconfig
Config/Local.xcconfig.example
Config/AppGroup.entitlements.example
PairNotes.xcodeproj/project.pbxproj
PairNotes.xcodeproj/xcshareddata/xcschemes/PairNotes.xcscheme
PairNotes/App/AppModel.swift
PairNotes/App/PairNotesApp.swift
PairNotes/App/RootView.swift
PairNotes/Features/Home/HomeView.swift
PairNotes/Features/Timeline/TimelineView.swift
PairNotes/Features/Couple/CoupleView.swift
PairNotes/Canvas/NativePaper/NativePaperProbe.swift
PairNotes/Canvas/NativePaper/PaperProbeController.swift
PairNotes/Canvas/NativePaper/PaperProbeDocument.swift
PairNotes/Core/Domain/NoteDocument.swift
PairNotes/Core/Domain/Providers.swift
PairNotes/Core/Mocks/MockProviders.swift
PairNotes/Core/Persistence/ContentDigest.swift
PairNotes/Core/Persistence/FileDraftStore.swift
PairNotes/Core/Persistence/WidgetSnapshotStore.swift
PairNotes/Widgets/NoteWidget/NoteWidget.swift
PairNotes/Widgets/NoteWidget/PairNotesWidgetBundle.swift
PairNotes/Widgets/SharedSnapshot/SharedWidgetContainer.swift
PairNotes/Tests/CoreTests/DraftStoreTests.swift
PairNotes/Tests/CoreTests/WidgetSnapshotTests.swift
PairNotes/Tests/NativeTests/PaperRoundTripTests.swift
docs/VALIDACION_INICIAL.md
docs/REFERENCIAS_M0.md
scripts/Gemfile
scripts/Gemfile.lock
scripts/generate_project.rb
```

Los outputs `.build/` del intento Nix quedan ignorados; la suite Docker usó `/tmp` dentro de un contenedor eliminado al terminar. No se inicializó Git ni se creó ninguna cuenta ni se desplegó un servicio.
