# Compilar PairNotes desde Linux con GitHub Actions

El workflow `PairNotes CI` se activa al subir cambios a `main`, abrir/actualizar un pull request o ejecutar **Actions → PairNotes CI → Run workflow**. No requiere secretos Apple: compila para simulador sin firma. El corte vigente reemplaza Firebase por Railway y agrega pruebas del backend y de servicios/widget/editor; sus resultados están en [VALIDACION_RAILWAY.md](VALIDACION_RAILWAY.md).

**Resultado histórico de M0 verificado el 4 de octubre de 2026:** [ejecución 37222564964](https://github.com/Niiihuel/pairnotes/actions/runs/37222564964), commit `7c60f870cb6542e92611ebd85275801a8e441055`, ambos jobs aprobados. Pasaron 15 tests Python del selector y 15 XCTest Swift en Linux; `build-for-testing` de app, extensión y tests con Xcode 26.0.1/SDK 26.0; y los 2 tests PaperKit en iPhone 16e simulado con iOS 26.2/Xcode 26.2. Incluye el icono oscuro. Los [PNG exportados e inspeccionados](evidence/m0/README.md) se conservan en el repositorio.

**Última suite ordinaria aprobada antes del espacio compartido:** [37239688732](https://github.com/Niiihuel/pairnotes/actions/runs/37239688732), commit `872dc6c`: tres jobs aprobados, 15 tests Python, 40 Core, 52 backend y 21 nativos (128 en total); cero fallos y sin reintentos de esta ejecución. Compilación SDK 26.0 y ejecución de tests iOS 26.2. El [registro de mejoras de la beta](MEJORAS_BETA.md) incluye alcance, diagnósticos no bloqueantes y capturas reales.

El [corte de perfiles, fechas, recuerdos, mensajes, distancia y avisos mensuales](ESPACIO_COMPARTIDO.md) amplía la suite. Su primer run `37242320713` compiló con SDK 26.0 pero detectó dos fallos en el editor; el registro del corte describe las correcciones y distingue las pruebas locales de la nueva ejecución Apple pendiente.

## Qué comprueba

1. En Ubuntu, ejecuta tests del selector de simulador y la suite XCTest portable en la imagen Swift fijada por digest. El selector se prueba con inventarios sintéticos; no simula haber ejecutado Xcode.
2. En `macos-26`, selecciona `/Applications/Xcode_26.0.1.app/Contents/Developer`, instala explícitamente el runtime **iOS 26.0 arm64** que requiere el compilador de catálogos y verifica que el SDK sea exactamente **iOS 26.0**. `build-for-testing` compila app, extensión y tests nativos con ese SDK.
3. Con Xcode **26.2**, descubre un iPhone disponible con runtime **iOS 26.2**, lo inicia y ejecuta las suites nativas de PaperKit, persistencia del editor, cliente del widget y configuración/sesión. No sustituye silenciosamente un runtime ausente por otro más nuevo.
4. Conserva logs, versiones reales del runner/Xcode/SDK, inventario del simulador, `.xcresult`, PNG adjuntos del roundtrip y la aplicación de simulador con su extensión. Un fallo de `xcodebuild` conserva su código de salida aunque la salida pase por `tee`.

El [inventario oficial de la imagen macOS](https://github.com/actions/runner-images/blob/6d942e630479cd99a93dadfc766af11242bfa402/images/macos/macos-26-arm64-Readme.md) consultado incluye SDK 26.0 y runtimes 26.2/26.4/26.5, pero no runtime 26.0. La [ejecución 37222127785](https://github.com/Niiihuel/pairnotes/actions/runs/37222127785) acreditó que agregar el catálogo de iconos hace fallar `actool` sin un runtime compatible con el SDK mínimo. Por eso se incorporó `xcodebuild -downloadPlatform iOS -buildVersion 26.0 -architectureVariant arm64`, sin `sudo` para la descarga, siguiendo [Apple](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components) y la [indicación de los mantenedores del runner](https://github.com/actions/runner-images/issues/13570). Se guardan inventarios antes/después y el log de instalación. Este paso añade tiempo y dependencia de red; si Apple no ofrece el runtime, falla explícitamente.

Compilación contra el SDK mínimo y ejecución sobre 26.2 son evidencias distintas. Ejecutar los tests sobre iOS **26.0 exacto** continúa pendiente aunque el runtime se instale para compilar recursos. Las rutas de Xcode fallan explícitamente si GitHub retira esas versiones; se deberán actualizar contra el inventario real, manteniendo el mínimo del producto.

## Revisar una ejecución desde Linux

En la página **Actions**, abrir el run del commit correspondiente. Los tres jobs (portable, backend e iOS) deben estar verdes. El job backend compila TypeScript y ejecuta sus tests con PostgreSQL y S3 de prueba. Descargar `linux-tests-<intento>` e `ios-evidence-<intento>`. El segundo contiene `ios-evidence.tar.gz`; al extraerlo:

- `artifacts/ios-minimum/environment.log` y `xcodebuild.log`: SDK y compilación mínima.
- `artifacts/ios-minimum/PairNotes-simulator.tar.gz`: `.app` con `.appex`, conservando permisos ejecutables.
- `artifacts/ios-tests/environment.log`, `devices.json` y `simulator-id.txt`: destino real de ejecución.
- `artifacts/ios-tests/test-summary.json`: resumen legible de los tests.
- `artifacts/ios-tests/attachments`: imágenes antes y después del roundtrip, cuando los tests llegaron a generarlas.
- `artifacts/ios-tests/Tests.xcresult`: resultado completo para investigar en Xcode cuando sea necesario.

Los adjuntos se intentan exportar también cuando el test falla. El artefacto pequeño `paperkit-renders-<intento>` permite descargar las imágenes y la fuente nativa sin bajar el paquete completo. Si la compilación falla antes de producir el bundle, no habrá imágenes ni resultados de tests. No se generan imágenes ficticias para suplirlos. Los artefactos se retienen 14 días.

La `.app` de este flujo **sólo sirve para simulador**. La [compilación firmada manual](#compilación-firmada-manual) usa los bundle IDs, App Group, certificado y perfiles del propietario para generar la IPA destinada a distribución. La suite ordinaria no registra capacidades, no publica una IPA ni modifica servicios. Tampoco valida App Groups reales, push, batería, GPS ni la apariencia de un widget en pantalla de inicio.

## Comandos locales de validación

```bash
python3 -m unittest discover -s scripts/ci/tests -v
actionlint .github/workflows/ci.yml
shellcheck scripts/ci/ios.sh
bundle install --gemfile scripts/Gemfile
BUNDLE_GEMFILE=scripts/Gemfile bundle exec ruby scripts/ci/validate_project.rb
```

En NixOS, se pueden ejecutar los linters mediante `nix shell nixpkgs#actionlint nixpkgs#shellcheck -c ...`. El verificador Ruby comprueba pertenencia de archivos, referencias del SDK, targets, extensión y esquema; no reemplaza la compilación.

`bash scripts/ci/ios.sh minimum` en Linux termina con código 2 y un mensaje explícito de entorno faltante. No convierte ese caso en una build exitosa.

## Compilación firmada manual

El flujo separado `.github/workflows/distribute.yml` prepara un archive Release y exporta una IPA para App Store Connect usando certificados y perfiles del propietario. Se ejecuta manualmente sobre `main`. Por defecto sólo exporta; el input explícito `upload_to_testflight=true` habilita la subida posterior mediante una clave API del propietario. La ficha existente usa la versión `1.0`, que se aplica a app y widget al archivar.

Desde el corte de espacio compartido, el flujo manual empieza en Ubuntu y exige que `PairNotes CI` del **mismo commit completo**, rama `main`, evento `push` y archivo `ci.yml` concluya `success`. Elige la ejecución/intento más reciente de esa SHA. Espera como máximo 15 minutos; falta de CI, fallo, cancelación o resultado inesperado bloquean archive y subida. Ambos jobs descargan explícitamente `github.sha`. El permiso `actions: read` y el token de consulta están limitados al job/paso de espera. Tras disparar este workflow, la comprobación y eventual subida continúan en GitHub aunque se cierre o reinicie la PC local.

Validación del gate: `actionlint`, `shellcheck` y 21 tests Python aprobados (15 del selector y 6 del gate). Una consulta real contra `8b08c9b` rechazó correctamente la CI fallida `37242320713`; no firmó ni subió nada. La nueva suite esperada es 21 Python + 54 Core + 65 backend + 33 nativos; el conteo esperado no se presenta como una ejecución aprobada.

**Archive/export firmado aprobado:** [ejecución 37236188455](https://github.com/Niiihuel/pairnotes/actions/runs/37236188455), commit `6cf5c90`, Xcode 26.2 (17C52), versión `1.0`, build `2.1`, mínimo iOS 26.0. La importación del P12 en Keychain, las firmas de app/widget, los perfiles embebidos, permisos de producción, grupos Keychain, manifiestos y configuración de API/Google pasaron. Logs sin warnings ni errores de compilación; limpieza temporal aprobada. [Evidencia pública](evidence/signing/signed-archive.json). La IPA y sus símbolos se conservan fuera de Git en el directorio local de builds y como artefactos privados de ese run durante 7 días. **No se subió a Apple.**

La firma usa cinco secretos de Actions: `PAIRNOTES_DISTRIBUTION_P12_BASE64`, `PAIRNOTES_DISTRIBUTION_P12_PASSWORD`, `PAIRNOTES_APP_PROFILE_BASE64`, `PAIRNOTES_WIDGET_PROFILE_BASE64` y `PAIRNOTES_IOS_CONFIG`. Se cargaron con la CLI por stdin. El workflow crea un Keychain temporal, instala cada perfil en su target y elimina el material temporal al terminar. El core estático no recibe un perfil de provisión. No se usa firma automática para crear o modificar recursos en Apple.

La subida opcional usa `scripts/ci/upload_testflight.sh`, verifica el hash y commit de la IPA exportada y recibe tres secretos separados: `PAIRNOTES_ASC_KEY_ID`, `PAIRNOTES_ASC_ISSUER_ID` y `PAIRNOTES_ASC_PRIVATE_KEY`. La clave se escribe en una carpeta temporal para `altool` y se elimina con trap y un paso `always`. No se cambian grupos, testers, declaración de cifrado ni publicación en App Store. El artefacto `upload-result.json` distingue recibo de upload de procesamiento y disponibilidad TestFlight; no conserva logs crudos de autenticación. Se verificaron linters, sintaxis y casos positivos/negativos del parser antes de ejecutarlo en macOS.

Los perfiles descargados se verificaron en Linux mediante firma CMS y cadena Apple, coincidencia del certificado, equipo, Bundle IDs, vigencia y capacidades. Esto no equivale a ejecutar Xcode ni a instalar la app: el resultado del archive/export en macOS se registra por separado. Las pruebas físicas de OAuth, APNs y widget siguen pendientes aunque la firma pase.

Validación local del corte de firma: 148 comprobaciones estructurales sobre el proyecto incluido y otro regenerado en una copia temporal, 15 tests Python del selector, actionlint, ShellCheck, sintaxis Bash/Ruby y rechazo explícito de distribución desde Linux. La app declara UserDefaults privado con razón `CA92.1`; la extensión no usa APIs propias que requieran razón. Ambos manifiestos se incluyen en Resources. Se añadieron las cuatro orientaciones para iPad sin cambiar las de iPhone. [Apple: manifiesto de APIs con razón requerida](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest).

Referencias: [GitHub: certificados y perfiles en Actions](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications), [Apple: subida de builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/).

## Primera build disponible en TestFlight

El 4 de octubre de 2026, [Actions 37237940506](https://github.com/Niiihuel/pairnotes/actions/runs/37237940506) completó archive, export y upload de `1.0 (3.1)`, commit `350e6891205341af7a517947c03299cfcaf98702`. Xcode 26.2 (17C52), mínimo iOS 26.0; firmas, perfiles, configuración y declaración de cifrado aprobados, sin warnings ni errores de compilación. La limpieza de claves temporales también terminó correctamente.

`altool` devolvió un recibo de éxito, sin errores, con Delivery UUID `da140206-e769-4109-a1b6-49000308f102`. La consulta autenticada posterior, a las `21:58:24 UTC`, confirmó procesamiento `VALID`, `usesNonExemptEncryption=false` y disponibilidad interna `IN_BETA_TESTING`. El único grupo asociado es `amorchi`, con tres cuentas de las dos personas autorizadas; no hay testers individuales adicionales. El grupo es interno y su campo `publicLinkEnabled` devuelve `null`, sin enlace público habilitado. No se pidió publicación en App Store ni distribución externa.

La [evidencia persistente](evidence/testflight/build-3.1.json) separa la verificación al exportar, el recibo de carga y la lectura posterior de Apple. Los campos `uploaded_to_apple=false` del paso de exportación y `not_checked` del recibo describen esos pasos anteriores, no el estado final. SHA-256 de la IPA: `4509599bac185d925353c6c5f8269388bb92b1d5ffa4ee1242ae8128bdff1d04`. IPA y símbolos: artefacto privado `pairnotes-signed-ipa-3-1`, retenido siete días, y copia fuera de Git en `~/.local/share/pairnotes/builds/1.0-3.1/`.

Comandos usados desde Linux para este corte: `rtk nix-shell -p shellcheck --run 'rtk shellcheck scripts/ci/distribute.sh scripts/ci/upload_testflight.sh'`, validación de plist y sintaxis Python embebida, `rtk git diff --check`, `gh workflow run distribute.yml --ref main --repo Niiihuel/pairnotes -f upload_to_testflight=true`, `gh run watch`, `gh run download` y consultas GET autenticadas de App Store Connect. Los comandos GitHub se ejecutaron con prefijo `rtk` y `GH_CONFIG_DIR` privado de PairNotes para seleccionar `Niiihuel`, sin cambiar la cuenta global. Se renovó su autorización con scope `workflow` para poder actualizar el workflow. En macOS, `distribute.sh` y `upload_testflight.sh` ejecutaron los comandos reales de Xcode, firma y `altool`.

Para esa primera subida se conservó la suite aprobada de 120 tests de [37236154698](https://github.com/Niiihuel/pairnotes/actions/runs/37236154698); no se volvió a ejecutar por los cambios de declaración, upload y documentación. Sí se compiló y verificó nuevamente la IPA. Quedaron pendientes instalación, OAuth y entrega de notas/APNs/widget en dos iPhones, porque este entorno Linux no tiene acceso a esos dispositivos. Las capturas posteriores del usuario permitieron identificar los ajustes de la siguiente actualización.

## Actualización de invitaciones y editor

La [build `1.0 (4.1)`](evidence/testflight/build-4.1.json), commit `b8a1f50`, se compiló, firmó y subió en [37240333996](https://github.com/Niiihuel/pairnotes/actions/runs/37240333996). Archive/export sin warnings ni errores; Apple confirmó `VALID` e `IN_BETA_TESTING`, acceso sólo para `amorchi` y cero testers individuales. Se conserva la IPA con símbolos fuera de Git en `~/.local/share/pairnotes/builds/1.0-4.1/`. Los [cambios, pruebas y capturas](MEJORAS_BETA.md) detallan el flujo de invitaciones, las acciones del editor y el color persistente de la hoja.

## Registro histórico del corte M0

Verificado localmente: 15 tests del selector, actionlint y ShellCheck. El verificador de proyecto ahora supera **96 comprobaciones** tanto sobre el proyecto incluido como tras regenerarlo en una copia temporal; incluye el catálogo del icono sólo en la app. La suite portable tiene 15 XCTest aprobados y se ejecuta de nuevo en CI. Se corrigió una referencia generada a `Foundation.framework` que apuntaba a iPhoneOS18.0; ahora resuelve contra `SDKROOT` tanto en el proyecto como en su generador.

El repositorio privado [Niiihuel/pairnotes](https://github.com/Niiihuel/pairnotes) ya está creado. En la [ejecución 37221416769](https://github.com/Niiihuel/pairnotes/actions/runs/37221416769), commit `b9cbb7a`, pasaron las pruebas Linux y la compilación de app, widget y tests con Xcode 26.0.1/SDK 26.0. En el simulador iPhone 16e/iOS 26.2 pasó el rechazo de fuente corrupta; el roundtrip falló exclusivamente por comparación exacta del raster.

La inspección de los PNG confirmó los tres elementos completos y orientados correctamente. Imagen y trazo son idénticos. El texto conserva sus 1287 píxeles de tinta con desplazamiento vertical uniforme de un píxel tras la primera restauración. El test refinado exige igualdad exacta fuera del texto, permite únicamente esa traslación vertical de hasta un píxel, compara el texto indexable y exige que una segunda restauración sea estable. El guardado ahora genera los derivados desde la fuente serializada y restaurada. **Todo ese test pasó en `37222564964`**, junto con el rechazo de fuente corrupta. También compiló el catálogo del nuevo icono con el SDK mínimo; el runtime instalado fue iOS 26.0, build `23A343`. El runner real fue macOS 26.6.2 arm64, imagen `20260907.0351.1`.

Queda una advertencia no bloqueante de catálogo: el setting generado de `AccentColor` no tiene aún un color definido. Se mantiene el acento del sistema; definir la paleta pertenece al siguiente trabajo de interfaz. No hubo fallos de tests en la ejecución final. No se ejecutaron pruebas interactivas de PhotosPicker, edición con dedo, accesibilidad, App Group firmado, widget visible ni pruebas físicas de push/consumo. Esas validaciones necesitan interacción y/o configuración de desarrollo/dispositivos, como detalla la validación inicial. La build de simulador tampoco acredita instalación en iPhone o distribución TestFlight.

El próximo corte de producto es **M2: identidad y vinculación segura**, empezando por contratos y Firebase Emulator Suite sin credenciales de producción, con tests negativos de invitaciones, pertenencia y acceso de un tercer usuario. El login Google/Apple real requiere configuración autorizada y se distinguirá de la prueba emulada. No se implementó M2 en este corte ni se avanzó a M3/Studio.

## Archivos y comandos de la continuación M0 (histórico)

- CI nuevo: `.github/workflows/ci.yml`, `scripts/ci/ios.sh`, `scripts/ci/select_simulator.py`, `scripts/ci/tests/test_select_simulator.py`, `scripts/ci/validate_project.rb` y este documento.
- Proyecto corregido: `PairNotes.xcodeproj/project.pbxproj` y `scripts/generate_project.rb` (referencia Foundation por SDK y recursos del icono).
- Editor corregido: `PaperProbeController.swift`, `PaperProbeDocument.swift`, `NativePaperProbe.swift` y `PaperRoundTripTests.swift` (inserción compatible con SDK 26, fixture, coordenadas de render, derivados de la fuente persistida y evidencia del roundtrip).
- Icono: original `icon.png` conservado; `PairNotes/App/Assets.xcassets/Contents.json` y `AppIcon.appiconset/{Contents.json,AppIcon.png}` agregados.
- Registro y exclusiones: `README.md`, `docs/VALIDACION_INICIAL.md`, `docs/REFERENCIAS_M0.md` y `.gitignore` actualizados. El plan recibido permanece intacto.
- Evidencia persistente: tres PNG reales del roundtrip y su procedencia en `docs/evidence/m0/`.

Comandos efectivamente utilizados en Linux, además de los de inspección y pruebas de la entrega inicial:

```bash
rtk python3 -m unittest discover -s scripts/ci/tests -v
rtk nix shell nixpkgs#actionlint nixpkgs#shellcheck -c actionlint .github/workflows/ci.yml
rtk nix shell nixpkgs#shellcheck -c shellcheck scripts/ci/ios.sh
rtk env GEM_HOME=/tmp/pairnotes-gems GEM_PATH=/tmp/pairnotes-gems nix shell nixpkgs#ruby -c ruby scripts/ci/validate_project.rb
rtk nix shell nixpkgs#imagemagick -c magick icon.png -background '#111118' -alpha remove -alpha off -resize 1024x1024 -strip PNG24:PairNotes/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
rtk git diff --check
```

Se ejecutaron `gh run list`, `gh run view --log-failed`, `gh run download` y `git push` usando la autenticación existente de `Niiihuel`, seleccionada sólo para cada proceso mediante un helper temporal. No se cambió la cuenta global activa ni se guardaron tokens en el repositorio. En macOS, el workflow ejecuta los comandos `xcodebuild`, `simctl` y `xcresulttool` que contiene `scripts/ci/ios.sh`; sus logs constituyen la evidencia, no el parse de Swift realizado en Linux.

## Configuración del workflow

Las acciones oficiales están fijadas a commits publicados: [checkout v7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1) y [upload-artifact v7.0.1](https://github.com/actions/upload-artifact/releases/tag/v7.0.1). El token sólo tiene `contents: read`, no se persisten credenciales en el checkout y no se usan secretos en pull requests. Los paquetes `.tar.gz` conservan permisos de los binarios, siguiendo la [documentación de artefactos de GitHub](https://github.com/actions/upload-artifact#permission-loss).

La suite anterior del corte de firma (commit `6bc5200`) finalizó aprobada en [37236154698](https://github.com/Niiihuel/pairnotes/actions/runs/37236154698): 15 tests Python, 36 Swift Linux, 52 backend y 17 XCTest nativos; cero fallos. Compilación con Xcode 26.0.1/SDK 26.0 y tests en simulador iOS 26.2/Xcode 26.2. No hubo reintentos de esa suite.
