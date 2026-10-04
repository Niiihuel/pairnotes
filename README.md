# PairNotes

App iOS nativa para compartir dibujos, texto y fotos entre dos personas. Swift/SwiftUI y PaperKit, iOS 26 mínimo. Se desarrolla desde Linux; la compilación Apple y los tests nativos se ejecutan con GitHub Actions. Repositorio privado: [Niiihuel/pairnotes](https://github.com/Niiihuel/pairnotes).

Por decisión del usuario, **Railway reemplaza Firebase**: API Node, PostgreSQL y almacenamiento S3 privado. Google y Apple siguen siendo proveedores de login. Las notificaciones se envían directamente por APNs. El [plan original](Plan_app_pareja_Swift.md) se conserva; la [enmienda de arquitectura y alcance](docs/RAILWAY_Y_FLUJO_NOTAS.md) documenta el cambio.

## Estado

Implementados: borradores múltiples con autosave, texto/fotos/trazo, exportación, sesiones y vinculación privada, cola de envíos con reintento, historial por días, último dibujo recibido, avisos APNs y widget con credencial propia. No hay datos ficticios presentados como notas recibidas reales. El editor local funciona sin configurar servicios.

Los IDs OAuth reales ya están cargados en la configuración local y Railway; la prueba entre dos iPhones todavía requiere firma, perfiles y clave APNs. La aceptación de push en APNs y la actualización visible del widget no se dan por comprobadas mediante tests con transporte simulado. El widget solicita actualizaciones; iOS decide cuándo mostrarlas. No se solicita ubicación ni se implementa todavía el widget de distancia o Studio/Metal.

La [validación inicial](docs/VALIDACION_INICIAL.md) y [CI](docs/CI_GITHUB_ACTIONS.md) conservan evidencia real de M0, incluido el roundtrip de texto/foto/trazo. Los resultados de este corte se registran en [VALIDACION_RAILWAY.md](docs/VALIDACION_RAILWAY.md).

## Estructura

- `PairNotes/App`, `Features` y `Canvas`: navegación, editor nativo, borradores, cola, historial y cuenta.
- `PairNotes/Core`: dominio Foundation y persistencia portable; sin UI, SDKs de login ni servicios externos.
- `PairNotes/Services`: Google/Apple, cliente HTTPS, sesión privada en Keychain y registro APNs.
- `PairNotes/Widgets`: extensión separada, acceso acotado al último recibido y caché con vencimiento.
- `Backend`: API, identidad OIDC, PostgreSQL, bucket privado, worker APNs y tests de integración.
- `Config`: ejemplos sin secretos; [configuración iOS](docs/CONFIGURACION_IOS.md).
- `PairNotes/Tests`: tests portables, persistencia nativa, configuración/sesiones y caché del widget.

## Pruebas

Core portable con Swift completo:

```bash
swift test
```

Alternativa verificada en este Linux:

```bash
docker run --rm -v "$PWD:/workspace:ro" -w /workspace \
  swift@sha256:eccc7a97f9b9881d9659e2e788081fd7675f86d39793b51200bfb178398b3784 \
  swift test --scratch-path /tmp/pairnotes-build
```

Backend: seguir [Backend/README.md](Backend/README.md). Usa PostgreSQL y S3 local reales, fixtures ficticios, firmas JWT generadas para las pruebas y transporte APNs controlado. No usa cuentas personales en tests.

GitHub Actions verifica Core/Python en Linux, backend con SQL/S3, compilación app/widget/tests con SDK 26.0 y tests nativos en simulador 26.2. Los scripts registran las versiones reales y guardan artefactos; no requieren firma para simulador.

En un Mac, abrir `PairNotes.xcodeproj` con scheme `PairNotes`. Para repetir los comandos de CI:

```bash
DEVELOPER_DIR=/Applications/Xcode_26.0.1.app/Contents/Developer bash scripts/ci/ios.sh minimum
DEVELOPER_DIR=/Applications/Xcode_26.2.app/Contents/Developer bash scripts/ci/ios.sh test
```

## Configuración de desarrollo

Railway contiene un proyecto `pairnotes-dev`, entorno `development`, PostgreSQL y bucket privado. El [registro de validación](docs/VALIDACION_RAILWAY.md) indica el despliegue y las comprobaciones realizadas. La API falla de forma cerrada para login si los IDs de proveedor no están configurados.

Para un iPhone firmado, completar los ejemplos de `Config` con IDs propios, capacidades legítimas y la URL HTTPS del servicio. Usar [CONFIGURACION_IOS.md](docs/CONFIGURACION_IOS.md); no guardar claves APNs, refresh tokens ni certificados en Git. La app usa un grupo Keychain privado y otro compartido sólo para el widget.

Crear permite dibujar sin cuenta. Al iniciar sesión, los dibujos de invitado se copian explícitamente a los borradores de esa cuenta. Vincular dos cuentas habilita Enviar. Cada envío conserva una revisión independiente; editar el borrador después no altera lo publicado. Todos los dibujos enviados permanecen consultables por días mientras la pareja siga vinculada.

## Icono de la app

Se conserva [icon.png](icon.png), proporcionado por el usuario. El catálogo `PairNotes/App/Assets.xcassets` contiene su adaptación de 1024 × 1024 RGB, con fondo oscuro `#111118` elegido por el usuario, sin cambiar el diseño ni redondear esquinas manualmente. Pertenece sólo al target de la app. Para reproducir la conversión con ImageMagick:

```bash
magick icon.png -background '#111118' -alpha remove -alpha off \
  -resize 1024x1024 -strip \
  PNG24:PairNotes/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```

## Regenerar el proyecto, sólo si hace falta

El `.xcodeproj` ya está incluido. Ruby sólo se necesita para regenerarlo después de agregar archivos, no para abrirlo ni compilarlo:

```bash
bundle install --gemfile scripts/Gemfile
BUNDLE_GEMFILE=scripts/Gemfile bundle exec ruby scripts/generate_project.rb --replace
```

`--replace` sobrescribe la configuración generada: revisar antes cambios manuales de Xcode. Conservar firma y valores propios en `Config/Local.xcconfig`.
