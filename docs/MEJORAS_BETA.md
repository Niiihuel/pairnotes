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

Pruebas portables de invitaciones: 40 tests Core aprobados en Linux con Swift 6.2.4 dentro de la imagen Docker fijada en el README. Validación estructural: 148 comprobaciones aprobadas. La compilación iOS, pruebas nativas de color/persistencia y distribución de este corte se registrarán tras ejecutarse en GitHub Actions; no se presentan estas comprobaciones Linux como una build iOS.

Queda una comprobación física después de instalar la nueva beta: compartir por WhatsApp, copiar/pegar ambos formatos, editar/cancelar el perfil, abrir los menús del editor, cambiar papel con interfaz clara y oscura, reabrir el borrador y comprobar que el mismo fondo llegue a la pareja y al widget. La entrega APNs y el momento de actualización del widget requieren observación real; no se deducen del render ni de la compilación.

Fuentes de las APIs: [ShareLink](https://developer.apple.com/documentation/swiftui/sharelink), [PasteButton](https://developer.apple.com/documentation/swiftui/pastebutton), [hojas de edición](https://developer.apple.com/design/human-interface-guidelines/sheets), [menús](https://developer.apple.com/design/human-interface-guidelines/menus), [PaperKit contentView](https://developer.apple.com/documentation/paperkit/papermarkupviewcontroller/contentview-4aeda), [RenderingOptions](https://developer.apple.com/documentation/paperkit/renderingoptions/init(darkuserinterfacestyle:layoutrighttoleft:)).
