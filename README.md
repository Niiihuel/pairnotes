# PairNotes

App iOS nativa para compartir dibujos, texto y fotos entre dos personas. Swift/SwiftUI y PaperKit, iOS 26 mínimo. Se desarrolla desde Linux; la compilación Apple y los tests nativos se ejecutan con GitHub Actions. Repositorio privado: [Niiihuel/pairnotes](https://github.com/Niiihuel/pairnotes).

Por decisión del usuario, **Railway reemplaza Firebase**: API Node, PostgreSQL y almacenamiento S3 privado. Google y Apple siguen siendo proveedores de login. Las notificaciones se envían directamente por APNs. El [plan original](Plan_app_pareja_Swift.md) se conserva; la [enmienda de arquitectura y alcance](docs/RAILWAY_Y_FLUJO_NOTAS.md) documenta el cambio.

## Estado

Implementados: borradores múltiples con autosave, texto/fotos/trazo, exportación, sesiones y vinculación privada, cola de envíos con reintento, historial por días, último dibujo recibido y avisos APNs. El [espacio compartido](docs/ESPACIO_COMPARTIDO.md) agrega fotos de perfil, recuerdos con fotos/fechas/dibujos, mensajes, fecha de inicio de la relación, aviso mensual opcional y widgets con credencial propia. El editor ofrece controles directos, recorte antes de insertar, selección, zoom, capas ordenables para textos/fotos/trazos y descarte nativo de cambios. El autoguardado mantiene el lienzo editable. Las fuentes v3 conservan las capas; los borradores v1/v2 se abren como una capa original. No hay datos ficticios presentados como notas recibidas reales. El editor local funciona sin configurar servicios.

Las fotos de perfil, recuerdos y dibujos reutilizan una caché privada en memoria/disco, con claves por cuenta, pareja y revisión de imagen. Los widgets se preparan y recuperan automáticamente; Nosotros ya no incluye un control de conexión manual. Inicio reúne su historia, mensajes y dibujos en tarjetas. Crear separa Borradores y Enviados, con vista previa y menú contextual al mantener presionado. Quitar un enviado de la lista es una preferencia local y conserva el recuerdo compartido.

La primera etapa de personalización agrega **Nosotros → A su manera**: temas crema/rosa/lavanda/noche, apodos, frase, portada elegida entre las fotos del álbum y orden compartido de Inicio. La revisión del servidor evita sobrescribir cambios simultáneos. Recuerdos presenta páginas Polaroid/postal/diario con stickers y dibujos vinculados. «Diseñar página por capas» permite combinar varias fotos y textos directamente desde un recuerdo, retomar su fuente nativa y compartir la composición completa sin recortarla. Las fuentes editables y la biblioteca de stickers se conservan por cuenta en este iPhone; al otro dispositivo llega la composición renderizada. El menú Detalles ofrece una biblioteca de stickers propios por cuenta (hasta 100 recortes, con opción circular), cuentagotas sobre el render real, alineación de la capa activa y guías con ajuste al centro. Las plantillas Postal, Dos Polaroids, Diario y Papel de carta se insertan en su propia capa. Las guías no se exportan. El papel de los nuevos dibujos sigue el tema; los existentes conservan su color.

Los formularios de recuerdos, mensajes y personalización conservan un borrador privado por cuenta/pareja/época en este iPhone. El guardado local nunca vuelve a cargar el texto durante la edición. Los mensajes guardan también su ID de envío para permitir reintentos sin duplicados. Eliminar un recuerdo ofrece deshacer durante 60 segundos en su pantalla de detalle y restaura su foto y metadatos. Las etapas siguientes también están implementadas localmente: Inicio permite enviar corazones, abrazos y besos con respuesta rápida y háptica; el widget «Te estoy pensando» muestra el último gesto y abre Inicio. Los dibujos recibidos admiten una reacción y una respuesta de hasta 280 caracteres. Cartitas permite elegir fecha/hora, escribir hasta 6000 caracteres y adjuntar una foto, un dibujo privado creado con el editor de capas, un dibujo ya compartido y voz de hasta 60 segundos. El micrófono se pide sólo al tocar Grabar; el audio se detiene al salir o ante una interrupción. El servidor oculta todos los campos de contenido y adjuntos al receptor hasta la fecha, y programa una notificación genérica. Las cartas cerradas son inmutables y sus reintentos no crean un segundo sobre. Las ondas de audio se calculan de las muestras reales, fuera del hilo de UI. Fotos ampliables con zoom y animaciones que respetan Reducir movimiento.

Crear ofrece deshacer durante 60 segundos para la última eliminación de borrador o elemento ocultado en Enviados, mientras la app permanece abierta. Restaurar no sobreescribe un borrador editado después. La compilación de app/widget y las pruebas nativas se verifican con el workflow PairNotes CI antes de distribuir. Las comprobaciones locales incluyen 76 pruebas del backend, 69 de Core y 21 del tooling de CI. Sigue siendo necesaria la prueba física de grabación, gestos, recorte y entrega de widgets en dos iPhones.

El nuevo corte está implementado y la distribución manual ahora espera una CI aprobada del mismo commit antes de firmar/subir. [Estado y pruebas pendientes](docs/ESPACIO_COMPARTIDO.md).

**Última beta interna confirmada:** versión `1.0 (4.1)`, generada y subida en [Actions 37240333996](https://github.com/Niiihuel/pairnotes/actions/runs/37240333996), commit `b8a1f50`. Apple confirmó procesamiento `VALID` y estado `IN_BETA_TESTING`; sólo está asociada al grupo `amorchi`, con las tres cuentas que el propietario confirmó como propias y de su pareja. [Evidencia de firma, subida y acceso](docs/evidence/testflight/build-4.1.json). Las [mejoras de la beta](docs/MEJORAS_BETA.md) incluyen invitaciones copiables, edición de perfil, acciones superiores del editor y papel blanco con color persistente. Pasaron 128 tests; las pruebas físicas de esta actualización siguen pendientes.

Los IDs OAuth reales y la clave APNs de producción ya están configurados. El certificado Apple Distribution y los perfiles de app/widget están verificados y cargados como secretos cifrados de GitHub Actions. El [flujo manual de firma](docs/CI_GITHUB_ACTIONS.md#compilación-firmada-manual) exporta la IPA y permite subirla con un input explícito. La aceptación de push en APNs y la actualización visible del widget no se dan por comprobadas mediante tests con transporte simulado. El widget solicita actualizaciones; iOS decide cuándo mostrarlas. La distancia es opcional: solicita ubicación sólo al activar la función, mientras se usa la app, y deja de mostrar distancias vencidas. Los avisos mensuales también están desactivados inicialmente y se habilitan en Nosotros → Nuestra fecha. Studio/Metal continúa pendiente.

La [validación inicial](docs/VALIDACION_INICIAL.md) y [CI](docs/CI_GITHUB_ACTIONS.md) conservan evidencia real de M0, incluido el roundtrip de texto/foto/trazo. Los resultados de este corte se registran en [VALIDACION_RAILWAY.md](docs/VALIDACION_RAILWAY.md).

## Estructura

- `PairNotes/App`, `Features` y `Canvas`: navegación, editor nativo, borradores, cola, historial y cuenta.
- `PairNotes/Core`: dominio Foundation y persistencia portable; sin UI, SDKs de login ni servicios externos.
- `PairNotes/Services`: Google/Apple, cliente HTTPS, sesión privada en Keychain y registro APNs.
- `PairNotes/Widgets`: extensión separada, dibujo/mensaje recibido, fechas y distancia; acceso acotado y caché con vencimiento.
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
