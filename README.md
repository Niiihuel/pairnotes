# PairNotes

App iOS nativa para compartir dibujos, texto y fotos entre dos personas. Swift/SwiftUI y PaperKit, iOS 26 mínimo. Se desarrolla desde Linux; la compilación Apple y los tests nativos se ejecutan con GitHub Actions. Repositorio público: [Niiihuel/pairnotes](https://github.com/Niiihuel/pairnotes).

Por decisión del usuario, **Railway reemplaza Firebase**: API Node, PostgreSQL y almacenamiento S3 privado. Google y Apple siguen siendo proveedores de login. Las notificaciones se envían directamente por APNs. El [plan original](Plan_app_pareja_Swift.md) se conserva; la [enmienda de arquitectura y alcance](docs/RAILWAY_Y_FLUJO_NOTAS.md) documenta el cambio.

## Estado

Implementados: borradores múltiples con autosave, texto/fotos/trazo, exportación, sesiones y vinculación privada, cola de envíos con reintento, historial por días, último dibujo recibido y avisos APNs. El [espacio compartido](docs/ESPACIO_COMPARTIDO.md) agrega fotos de perfil, recuerdos con fotos/fechas/dibujos, mensajes, fecha de inicio de la relación, aviso mensual opcional y widgets con credencial propia. El editor ofrece controles directos, recorte antes de insertar, selección, zoom, capas ordenables para textos/fotos/trazos y descarte nativo de cambios. El autoguardado mantiene el lienzo editable. Las fuentes v3 conservan las capas; los borradores v1/v2 se abren como una capa original. No hay datos ficticios presentados como notas recibidas reales. El editor local funciona sin configurar servicios.

Las fotos de perfil, recuerdos y dibujos reutilizan una caché privada en memoria/disco, con claves por cuenta, pareja y revisión de imagen. Los widgets se preparan y recuperan automáticamente; Nosotros ya no incluye un control de conexión manual. Inicio reúne su historia, mensajes y dibujos en tarjetas. Dibujos separa Borradores y Enviados, con vista previa y menú contextual al mantener presionado. Quitar un enviado de la lista es una preferencia local y conserva el recuerdo compartido.

La navegación distingue Inicio, Dibujos, Recuerdos, Para vos y Nosotros. Para vos reúne las colecciones Cartas, Audios, Mensajes y Fotos; Nosotros concentra perfiles y ajustes. Las cartas usan papel crema, renglones, margen, sobres y tipografía serif de sistema inspirados en `para-vos`, con modo oscuro y Dynamic Type. Audios tiene grabador y revisión propios, salida de audio nativa y un borrador independiente de las cartas. Conserva la apertura programada del contrato de cartas: la fecha se muestra antes de enviar y el receptor sólo puede reproducir cuando el servidor permite abrir el contenido. Fotos muestra la última recibida, sin presentar un historial que la API aún no ofrece.

La primera etapa de personalización agrega **Nosotros → Apariencia**: temas crema/rosa/lavanda/noche, apodos, frase, portada elegida entre las fotos del álbum y orden compartido de Inicio. La revisión del servidor evita sobrescribir cambios simultáneos. Recuerdos presenta páginas Polaroid/postal/diario con stickers y dibujos vinculados. «Diseñar página» permite combinar varias fotos y textos directamente desde un recuerdo, retomar su fuente nativa y compartir la composición completa sin recortarla. Las fuentes editables y la biblioteca de stickers se conservan por cuenta en este iPhone; al otro dispositivo llega la composición renderizada. El menú Detalles ofrece una biblioteca de stickers propios por cuenta (hasta 100 recortes, con opción circular), cuentagotas sobre el render real, alineación de la capa activa y guías con ajuste al centro. Las plantillas Postal, Dos Polaroids, Diario y Papel de carta se insertan en su propia capa. Las guías no se exportan. El papel de los nuevos dibujos sigue el tema; los existentes conservan su color. La apariencia de la app recuerda Noche antes del primer render, por cuenta y servidor; las otras paletas respetan el modo claro/oscuro del sistema con superficies adaptadas.

Los formularios de recuerdos, mensajes y personalización conservan un borrador privado por cuenta/pareja/época en este iPhone. El guardado local nunca vuelve a cargar el texto durante la edición. Los mensajes guardan también su ID de envío para permitir reintentos sin duplicados. Eliminar un recuerdo ofrece deshacer durante 60 segundos en su pantalla de detalle y restaura su foto y metadatos. Las etapas siguientes también están implementadas localmente: Inicio permite enviar corazones, abrazos y besos con respuesta rápida y háptica; el widget «Te estoy pensando» muestra el último gesto y abre Inicio. Los dibujos recibidos admiten una reacción y una respuesta de hasta 280 caracteres. Cartitas permite elegir fecha/hora, escribir hasta 6000 caracteres y adjuntar una foto, un dibujo privado creado con el editor de capas, un dibujo ya compartido y voz de hasta 60 segundos. El micrófono se pide sólo al tocar Grabar; el medidor usa la señal real y la revisión ofrece pausa, duración y recorrido accesible. Al pasar a segundo plano o recibir una interrupción, la reproducción se pausa y conserva su posición; al salir, se detiene. Cartas distingue borradores, sobres pendientes y cartas abiertas, y explica qué falta antes de enviarlas. El servidor oculta todos los campos de contenido y adjuntos al receptor hasta la fecha, y programa una notificación genérica. Las cartas cerradas son inmutables y sus reintentos no crean un segundo sobre. Las ondas de audio se calculan de las muestras reales, fuera del hilo de UI. Fotos ampliables con zoom y animaciones que respetan Reducir movimiento.

Dibujos ofrece deshacer durante 60 segundos para la última eliminación de borrador o elemento ocultado en Enviados, mientras la app permanece abierta. Restaurar no sobreescribe un borrador editado después. La compilación de app/widget y las pruebas nativas se verifican con el workflow PairNotes CI antes de distribuir. Las comprobaciones locales incluyen 82 pruebas/subpruebas del backend, 72 de Core y 21 del tooling de CI. Sigue siendo necesaria la prueba física de grabación, gestos, recorte y entrega de widgets en dos iPhones.

El nuevo corte está implementado y la distribución manual ahora espera una CI aprobada del mismo commit antes de firmar/subir. [Estado y pruebas pendientes](docs/ESPACIO_COMPARTIDO.md).

**Última beta interna confirmada:** versión `1.0 (7.1)`, generada y subida en [Actions 37390384294](https://github.com/Niiihuel/pairnotes/actions/runs/37390384294), commit `d182fe0`, integrado en `main`. Apple confirmó procesamiento `VALID` y estado `IN_BETA_TESTING`; sólo está asociada al grupo interno `amorchi`, sin testers individuales adicionales ni enlace público. [Evidencia de firma, subida y acceso](docs/evidence/testflight/build-7.1.json). La [CI de main](https://github.com/Niiihuel/pairnotes/actions/runs/37388999209) aprobó backend, Core y pruebas nativas. El backend actualizado está desplegado en el entorno `development` de Railway que usa la beta. Las pruebas físicas en los dos iPhones siguen pendientes.

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

La rama `fix/editor-input-photo-widgets` corrige la coordinación del lienzo con la paleta de PaperKit y usa un selector de fotos con cierre secuencial antes del recorte en Crear, Perfil, Recuerdos y Cartitas. Agrega fotos directas desde Inicio o `pairnotes://camera`, reacciones desde un widget mediano/grande y una Live Activity temporal para mostrar la foto en la pantalla bloqueada. El widget de distancia acerca/separa los avatares con datos recientes y conserva estados de ubicación pausada o vencida. Estos cambios requieren una nueva compilación de la app y el backend actualizado; la beta instalada `1.0 (7.1)` conserva el comportamiento anterior.

El diseño sigue la documentación oficial de Apple para [widgets](https://developer.apple.com/design/human-interface-guidelines/widgets), [interacciones con App Intents](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities), [Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities) y [acceso a la cámara](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media). La cámara se abre en la app y permite revisar antes de enviar. La tarjeta de bloqueo se inicia desde la foto con «Mostrar en pantalla bloqueada»; su estado dura hasta ocho horas, y al quedar vencida oculta la foto y el mensaje. iOS puede conservar la tarjeta finalizada hasta cuatro horas más. Al volver a la app se cierra si cambió la cuenta/pareja o la foto actual. Esta Live Activity se actualiza desde la app y los botones de reacción; no incluye push de ActivityKit para sustituir fotos con la app cerrada. Las actualizaciones de widgets siguen bajo control de iOS.

Validación: pasan 80 pruebas de backend, 72 de Core y 21 de tooling. La compilación con el SDK mínimo de iOS 26.0 y las 56 pruebas nativas de la rama base pasaron; el simulador confirmó tinta con gestos reales y al alternar Seleccionar/Dibujar. El target UI también comprueba cancelación de Fotos y guardado/reapertura. Los resultados del recorrido completo y las capturas se registran en el [PR #1](https://github.com/Niiihuel/pairnotes/pull/1) y sus ejecuciones de Actions. El contraste usa `colorSchemeContrast` y respeta los ajustes del sistema. No se publicó una nueva beta.

La rama `ux/letters-and-separated-flows` continúa sobre esa corrección: elimina accesos repetidos y textos explicativos, separa el borrador de voz del de carta y espera el cierre real de los modales antes de atender enlaces o notificaciones. Las notificaciones de mensajes esperan a que la sesión y la pareja estén resueltas. Pasaron la prueba de navegación entre las cinco secciones y la prueba nativa que verifica que preparar otro reproductor no interrumpa el audio activo. Hay capturas de cartas y controles de audio en claro y oscuro. Pasan la sintaxis Swift y 219 comprobaciones estructurales del proyecto. El resultado final y la revisión visual se registran en el [PR #2](https://github.com/Niiihuel/pairnotes/pull/2). Guías aplicadas: [navegación por tabs](https://developer.apple.com/design/human-interface-guidelines/tab-bars), [sheets](https://developer.apple.com/design/human-interface-guidelines/sheets), [audio](https://developer.apple.com/design/human-interface-guidelines/playing-audio) y [accesibilidad](https://developer.apple.com/design/human-interface-guidelines/accessibility).

La rama `fix/widget-avatars-notification-names` conserva el color y la transparencia originales de las fotos de perfil, mejora el contraste de iniciales/bordes y usa una silueta genérica cuando iOS oculta el contenido privado. En la pantalla bloqueada, WidgetKit conserva su tratamiento monocromático. Los avisos usan el nombre actualizado del remitente como título; perfiles sin nombre válido muestran «PairNotes». Se validan el actor, el contenido y la época del vínculo antes de enviar. Pasan 82/82 pruebas de backend, 222 comprobaciones estructurales y las cuatro pruebas nativas de avatares con el SDK de Apple. Hay previews de color, tinte, bloqueo y privacidad; el compositor final de WidgetKit requiere prueba en dispositivo. Los resultados de la rama integrada se registran en el [PR #3](https://github.com/Niiihuel/pairnotes/pull/3). Guía aplicada: [renderizado con tinte y Liquid Glass](https://developer.apple.com/documentation/widgetkit/optimizing-your-widget-for-accented-rendering-mode-and-liquid-glass).

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

Dibujos permite dibujar sin cuenta. Al iniciar sesión, los dibujos de invitado se copian explícitamente a los borradores de esa cuenta. Vincular dos cuentas habilita Enviar. Cada envío conserva una revisión independiente; editar el borrador después no altera lo publicado. Todos los dibujos enviados permanecen consultables por días mientras la pareja siga vinculada.

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
