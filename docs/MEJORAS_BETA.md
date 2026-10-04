# Ajustes tras la primera prueba en iPhone

## Invitaciones y perfil

La versión inicial enviaba el código como `ShareLink.item` y las instrucciones como `message`; la actividad de WhatsApp podía unirlos sin un formato claro. Ahora se comparte un único texto, con el código en su propia línea, y existe una acción separada **Copiar código**. El portapapeles se escribe sólo por ese gesto y la copia caduca con la invitación; no se lee automáticamente.

**Tengo una invitación** abre un formulario con el control nativo Pegar. Acepta el código solo, el mensaje completo nuevo y el mensaje generado por la primera beta. Sólo reconoce esos formatos, con un único código ASCII de 43 caracteres; no repara códigos cortados, extrae secretos de URLs ni reduce la entropía. El servidor conserva la validación de vigencia, pertenencia y uso único. Los tests utilizan exclusivamente códigos ficticios.

Nosotros muestra el nombre guardado; **Editar perfil** abre una hoja con Cancelar/Guardar, valida el nombre y conserva el error si falla la solicitud. Las acciones secundarias de cuenta, pareja e invitación pasan a menús accesibles. Reemplazar o revocar una invitación requiere confirmación. Un cambio de cuenta cierra los formularios y limpia el código; una vinculación detectada invalida la invitación mostrada. La confirmación de desvinculación conserva la identidad de la pareja antes de reautenticar.

## Editor y papel

El título se muestra en la barra de navegación y se modifica mediante **Renombrar**. **Listo** guarda antes de cerrar y **Enviar** queda arriba; Guardar borrador, Exportar imagen, Color de la hoja y las herramientas adicionales están en el menú superior. Se retiran las acciones inferiores que quedaban bajo la paleta de PencilKit. El accesorio de texto usa un icono y etiqueta accesible, en lugar del título truncado «Te…»; también hay una acción Agregar texto en el menú.

La hoja es blanca inicialmente, con contorno y separación visual del fondo de la interfaz. El selector permite colores predefinidos y un color opaco personalizado. Se usa `PaperMarkupViewController.contentView`, disponible en iOS 26, para colocar el papel debajo de los elementos. `PaperMarkup.backgroundColor` pertenece a iOS 27 y no se usa en este proyecto con SDK 26.

La fuente editable nueva contiene un envoltorio binario versionado con RGB opaco y los bytes PaperKit; el hash cubre ambos. `minimumEditorVersion=2` identifica esta representación. Los borradores anteriores, con fuente PaperKit directa y versión 1, se restauran sobre blanco; las versiones desconocidas conservan sus archivos y vista previa sin editar. El color se captura con la misma revisión y se aplica a los PNG final, widget y miniatura. Cambiar un borrador no modifica una nota ya enviada.

## Validación

[CI 37239688732](https://github.com/Niiihuel/pairnotes/actions/runs/37239688732), commit `872dc6c58d598a56b1d35cd2929a87d1f665f87d`, aprobada: **128 tests** (15 Python, 40 Swift Core, 52 backend y 21 XCTest nativos), sin fallos. App, widget y tests compilaron con SDK 26.0; los tests nativos corrieron en iPhone 16e simulado con iOS 26.2. Pasaron fondo opaco en todos los renders, reapertura del color, cambio de hash por color, conservación/migración de fuentes anteriores y rechazo de formatos futuros. El commit posterior `b8a1f50` sólo deshabilita Guardar del diálogo Renombrar durante una operación; su compilación Release quedó verificada al distribuir.

También pasaron 148 comprobaciones estructurales, `git diff --check` y parse de sintaxis Swift en Linux. La sintaxis sola no acredita compilación iOS. El log nativo contiene un aviso por destinos arm64/x86_64 duplicados y un diagnóstico de ImageIO porque la imagen ficticia de 400 × 300 se inserta a 900 × 675; no hubo errores de compilación ni fallos del test asociado.

Capturas reales inspeccionadas: [modo claro](evidence/beta-ui/editor-light.png), [modo oscuro](evidence/beta-ui/editor-dark.png), [procedencia](evidence/beta-ui/capture-info.json). Confirman hoja blanca y controles superiores. Se capturó la ventana de UIHostingController: la paleta nativa flotante no aparece en esos PNG; su interacción y la ausencia de solapamientos en el dispositivo deben comprobarse físicamente.

Queda una comprobación física después de instalar la nueva beta: compartir por WhatsApp, copiar/pegar ambos formatos, editar/cancelar el perfil, abrir los menús del editor, cambiar papel con interfaz clara y oscura, reabrir el borrador y comprobar que el mismo fondo llegue a la pareja y al widget. La entrega APNs y el momento de actualización del widget requieren observación real; no se deducen del render ni de la compilación.

Archivos del corte: `CoupleView.swift`, `Pairing.swift` y `PairTimelineTests.swift` para perfil/invitaciones; `NativePaperProbe.swift`, `PaperProbeController.swift`, `PaperProbeDocument.swift`, `NoteDocument.swift` y `NativeEditorPersistenceTests.swift` para editor/persistencia; este registro y las capturas de `docs/evidence/beta-ui/`. No cambiaron el backend, las credenciales, los permisos ni los grupos de testers.

Comandos ejecutados: `rtk docker run … swift test` para Core; `rtk docker run … swiftc -frontend -parse …` como revisión sintáctica; `rtk env GEM_HOME=/tmp/pairnotes-gems GEM_PATH=/tmp/pairnotes-gems nix-shell -p ruby --run 'rtk ruby scripts/ci/validate_project.rb'`; `rtk git diff --check`; `gh run view`, `gh run watch` y `gh run download` con prefijo `rtk` y la configuración privada de GitHub de PairNotes. La CI ejecutó los comandos Xcode de `scripts/ci/ios.sh`; no hubo Xcode local en Linux.

## Distribución y siguiente comprobación

La versión **1.0 (4.1)** del commit `b8a1f50dfa5c44b8b83be9c37dbd2a04c498dff4` se compiló, firmó y subió en [Actions 37240333996](https://github.com/Niiihuel/pairnotes/actions/runs/37240333996), sin warnings ni errores de compilación. La consulta real de Apple del 4 de octubre de 2026 a las `22:36:06 UTC` confirmó `VALID` e `IN_BETA_TESTING`, acceso únicamente para `amorchi` (las tres cuentas de las dos personas autorizadas) y cero testers individuales. No se solicitó publicación en App Store. [Evidencia de exportación, recibo de subida y consulta posterior](evidence/testflight/build-4.1.json).

La IPA y sus símbolos se conservan fuera de Git en `~/.local/share/pairnotes/builds/1.0-4.1/`. El siguiente corte es actualizar ambos iPhones desde TestFlight y realizar la comprobación física descrita arriba, especialmente WhatsApp y la paleta flotante. Las capturas del simulador y los tests no sustituyen esa interacción.

Fuentes de las APIs: [ShareLink](https://developer.apple.com/documentation/swiftui/sharelink), [PasteButton](https://developer.apple.com/documentation/swiftui/pastebutton), [hojas de edición](https://developer.apple.com/design/human-interface-guidelines/sheets), [menús](https://developer.apple.com/design/human-interface-guidelines/menus), [PaperKit contentView](https://developer.apple.com/documentation/paperkit/papermarkupviewcontroller/contentview-4aeda), [RenderingOptions](https://developer.apple.com/documentation/paperkit/renderingoptions/init(darkuserinterfacestyle:layoutrighttoleft:)).
