# Compilar PairNotes desde Linux con GitHub Actions

Alcance: continuar M0/M1 sin Mac propio. El workflow `PairNotes CI` se activa al subir cambios a `main`, abrir/actualizar un pull request o ejecutar **Actions → PairNotes CI → Run workflow**. No requiere secretos Apple ni Firebase: compila para simulador sin firma.

## Qué comprueba

1. En Ubuntu, ejecuta tests del selector de simulador y la suite XCTest portable en la imagen Swift fijada por digest. El selector se prueba con inventarios sintéticos; no simula haber ejecutado Xcode.
2. En `macos-26`, usa `/Applications/Xcode_26.0.1.app/Contents/Developer` y verifica que el SDK sea exactamente **iOS 26.0**. `build-for-testing` compila app, extensión y tests nativos con ese SDK.
3. Con Xcode **26.2**, descubre un iPhone disponible con runtime **iOS 26.2**, lo inicia y ejecuta `PaperRoundTripTests`. No sustituye silenciosamente un runtime ausente por otro más nuevo.
4. Conserva logs, versiones reales del runner/Xcode/SDK, inventario del simulador, `.xcresult`, PNG adjuntos del roundtrip y la aplicación de simulador con su extensión. Un fallo de `xcodebuild` conserva su código de salida aunque la salida pase por `tee`.

El [inventario oficial de la imagen macOS](https://github.com/actions/runner-images/blob/6d942e630479cd99a93dadfc766af11242bfa402/images/macos/macos-26-arm64-Readme.md) consultado incluye SDK 26.0 y runtimes 26.2/26.4/26.5, pero no runtime 26.0. Por eso compilación contra el SDK mínimo y ejecución sobre 26.2 son evidencias distintas. Ejecutar sobre iOS **26.0 exacto** continúa pendiente. Las rutas de Xcode fallan explícitamente si GitHub retira esas versiones; se deberán actualizar contra el inventario real, manteniendo el mínimo del producto.

## Revisar una ejecución desde Linux

En la página **Actions**, abrir el run del commit correspondiente. Ambos jobs deben estar verdes. Descargar `linux-tests-<intento>` e `ios-evidence-<intento>`. El segundo contiene `ios-evidence.tar.gz`; al extraerlo:

- `artifacts/ios-minimum/environment.log` y `xcodebuild.log`: SDK y compilación mínima.
- `artifacts/ios-minimum/PairNotes-simulator.tar.gz`: `.app` con `.appex`, conservando permisos ejecutables.
- `artifacts/ios-tests/environment.log`, `devices.json` y `simulator-id.txt`: destino real de ejecución.
- `artifacts/ios-tests/test-summary.json`: resumen legible de los tests.
- `artifacts/ios-tests/attachments`: imágenes antes y después del roundtrip, cuando los tests llegaron a generarlas.
- `artifacts/ios-tests/Tests.xcresult`: resultado completo para investigar en Xcode cuando sea necesario.

Los adjuntos se intentan exportar también cuando el test falla. El artefacto pequeño `paperkit-renders-<intento>` permite descargar las imágenes y la fuente nativa sin bajar el paquete completo. Si la compilación falla antes de producir el bundle, no habrá imágenes ni resultados de tests. No se generan imágenes ficticias para suplirlos. Los artefactos se retienen 14 días.

La `.app` de este flujo **sólo sirve para simulador**. Instalar en iPhone/TestFlight requerirá un flujo posterior con bundle IDs, App Group, firma y provisioning propios. Este workflow no registra capacidades, no publica una IPA y no despliega Firebase. Tampoco valida App Groups reales, push, batería, GPS ni la apariencia de un widget en pantalla de inicio.

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

## Estado de este corte

Verificado localmente: 15 tests del selector, actionlint y ShellCheck. El verificador de proyecto ahora supera **96 comprobaciones** tanto sobre el proyecto incluido como tras regenerarlo en una copia temporal; incluye el catálogo del icono sólo en la app. La suite portable tiene 15 XCTest aprobados y se ejecuta de nuevo en CI. Se corrigió una referencia generada a `Foundation.framework` que apuntaba a iPhoneOS18.0; ahora resuelve contra `SDKROOT` tanto en el proyecto como en su generador.

El repositorio privado [Niiihuel/pairnotes](https://github.com/Niiihuel/pairnotes) ya está creado. En la [ejecución 37221416769](https://github.com/Niiihuel/pairnotes/actions/runs/37221416769), commit `b9cbb7a`, pasaron las pruebas Linux y la compilación de app, widget y tests con Xcode 26.0.1/SDK 26.0. En el simulador iPhone 16e/iOS 26.2 pasó el rechazo de fuente corrupta; el roundtrip falló exclusivamente por comparación exacta del raster.

La inspección de los PNG confirmó los tres elementos completos y orientados correctamente. Imagen y trazo son idénticos. El texto conserva sus 1287 píxeles de tinta con desplazamiento vertical uniforme de un píxel tras la primera restauración. El test refinado exige igualdad exacta fuera del texto, permite únicamente esa traslación vertical de hasta un píxel, compara el texto indexable y exige que una segunda restauración sea estable. El guardado ahora genera los derivados desde la fuente serializada y restaurada. Su ejecución y la compilación del nuevo icono se registrarán al terminar el siguiente run; aún no se dan por aprobadas.

El próximo corte de producto es **M2: identidad y vinculación segura**, empezando por contratos y Firebase Emulator Suite sin credenciales de producción, con tests negativos de invitaciones, pertenencia y acceso de un tercer usuario. El login Google/Apple real requiere configuración autorizada y se distinguirá de la prueba emulada. No se implementó M2 en este corte ni se avanzó a M3/Studio.

## Configuración del workflow

Las acciones oficiales están fijadas a commits publicados: [checkout v7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1) y [upload-artifact v7.0.1](https://github.com/actions/upload-artifact/releases/tag/v7.0.1). El token sólo tiene `contents: read`, no se persisten credenciales en el checkout y no se usan secretos en pull requests. Los paquetes `.tar.gz` conservan permisos de los binarios, siguiendo la [documentación de artefactos de GitHub](https://github.com/actions/upload-artifact#permission-loss).
