# Referencias verificadas para M0

Consulta: 2026-10-04. Este registro complementa `Plan_app_pareja_Swift.md`; no reemplaza ni reconstruye el `FUENTES.md` mencionado en el encargo, que no estaba presente al inspeccionar el repositorio. Las referencias documentales describen contratos publicados; cuando hay evidencia de compilación se distingue expresamente de esa documentación. La [ejecución 37221416769](https://github.com/Niiihuel/pairnotes/actions/runs/37221416769), commit `b9cbb7a`, compiló app, Widget Extension y tests mediante `build-for-testing` con Xcode 26.0.1 y SDK 26.0. La suite nativa de esa ejecución todavía falló en la comparación exacta de píxeles del roundtrip; no acredita la aceptación completa de M0/M1.

## PaperKit en iOS 26

La documentación de [`PaperMarkup`](https://developer.apple.com/documentation/paperkit/papermarkup) declara disponibilidad desde iOS 26. Apple presenta el editor mixto, su integración con PencilKit y la separación entre modelo, controlador y menú en [Meet PaperKit, WWDC25](https://developer.apple.com/videos/play/wwdc2025/285/).

La documentación consultada ofrece archivos Markdown mediante el enlace «View Markdown». Sus metadatos declaran disponibilidad desde iOS 26 para los siguientes símbolos; no se dedujo su disponibilidad de que aparezcan en el índice actual del framework. Esa declaración no prueba que todas las conformidades de protocolo o ejemplos de la documentación actual compilen con el SDK 26.0.

### Construir el editor

- [`PaperMarkup(bounds:)`](https://developer.apple.com/documentation/paperkit/papermarkup/init(bounds:)): inicializa el lienzo.
- [`PaperMarkupViewController(markup:supportedFeatureSet:)`](https://developer.apple.com/documentation/paperkit/papermarkupviewcontroller/init(markup:supportedfeatureset:)): recibe un modelo opcional y las funciones permitidas.
- [`FeatureSet.version1`](https://developer.apple.com/documentation/paperkit/featureset/version1): fija la versión funcional inicial; Apple recomienda una versión específica cuando se quiere evitar que una actualización active herramientas inesperadas. Para este corte se propone `.version1`, con `colorMaximumLinearExposure = 1` para SDR.
- [`directTouchMode`](https://developer.apple.com/documentation/paperkit/papermarkupviewcontroller/directtouchmode) usa `.selection` por defecto. [`TouchMode`](https://developer.apple.com/documentation/paperkit/papermarkupviewcontroller/touchmode) dispone de `.drawing` y `.selection`; el experimento debe permitir dibujar con dedo y volver a seleccionar objetos.

La [guía de integración](https://developer.apple.com/documentation/paperkit/getting-started-with-paperkit) documenta el adaptador `UIViewControllerRepresentable`, `PKToolPicker`, el observador del controlador y `pencilKitResponderState.activeToolPicker`/`toolPickerVisibility`. También presenta `MarkupEditViewController` con el controlador del canvas como delegado; esa integración no quedó validada para el SDK mínimo.

**Contraste con compilación real:** la [primera ejecución de GitHub Actions](https://github.com/Niiihuel/pairnotes/actions/runs/37220239241), con Xcode 26.0.1 y SDK iOS 26.0, rechazó `insertion.delegate = canvas`: el compilador no reconoció la conformidad requerida de `PaperMarkupViewController` con `MarkupEditViewController.Delegate`. La documentación online actual y el SDK mínimo no deben tratarse como superficies idénticas. El experimento reemplazó ese menú por un `UIAlertController` para ingresar texto y la llamada al modelo `insertNewTextbox(attributedText:frame:rotation:)`, cuya disponibilidad está documentada desde iOS 26. Esa corrección sí compiló con el SDK mínimo en la ejecución `37221416769`. La edición visual interactiva y el ciclo de vida del editor en iPhone siguen pendientes.

La revisión comprobó otros valores predeterminados relevantes: [`directTouchAutomaticallyDraws`](https://developer.apple.com/documentation/paperkit/papermarkupviewcontroller/directtouchautomaticallydraws) puede anular el modo de selección; el adaptador lo desactiva para que el control explícito gobierne el dedo. [`zoomRange`](https://developer.apple.com/documentation/paperkit/papermarkupviewcontroller/zoomrange) empieza en `1...1`; se amplía y se usa [`setContentVisibleFrame`](https://developer.apple.com/documentation/paperkit/papermarkupviewcontroller/setcontentvisibleframe(_:animated:)) para encuadrar el lienzo completo. [`isEditable`](https://developer.apple.com/documentation/paperkit/papermarkupviewcontroller/iseditable) permite bloquear cambios durante la captura. Todos estos símbolos declaran disponibilidad iOS 26.

La entrada de fotos usa el patrón de [PhotosPicker y Transferable de Apple](https://developer.apple.com/documentation/photokit/bringing-photos-picker-to-your-swiftui-app). El ensayo limita la foto aceptada a 20 MB tras cargarla, pero esa comprobación no limita el pico previo de memoria: antes del editor de producción conviene adoptar una representación de archivo para entradas grandes y medir el pipeline.

### Insertar texto, imagen y dibujo

Las siguientes declaraciones están publicadas para iOS 26. La imagen recibida es un `CGImage`; elegirla o decodificarla y normalizar su orientación es responsabilidad del adaptador de medios.

```swift
mutating func insertNewImage(_ image: CGImage, frame: CGRect, rotation: CGFloat = 0)
mutating func insertNewTextbox(attributedText: NSAttributedString, frame: CGRect, rotation: CGFloat = 0)
mutating func append(contentsOf drawing: PKDrawing)
```

Fuentes individuales: [imagen](https://developer.apple.com/documentation/paperkit/papermarkup/insertnewimage(_:frame:rotation:)), [texto](https://developer.apple.com/documentation/paperkit/papermarkup/insertnewtextbox(attributedtext:frame:rotation:)-67igk), [trazos PencilKit](https://developer.apple.com/documentation/paperkit/papermarkup/append(contentsof:)-5tgti). La composición de prueba que usa estas operaciones compiló en GitHub Actions con SDK 26.0 y se ejecutó en simulador iOS 26.2; no se compiló iOS desde Linux.

Para construir un trazo de prueba, las siguientes firmas Swift tienen disponibilidad documentada desde iOS 14, suficiente para el mínimo 26:

```swift
// PKStrokePoint
init(location: CGPoint, timeOffset: TimeInterval, size: CGSize, opacity: CGFloat, force: CGFloat, azimuth: CGFloat, altitude: CGFloat)
// PKStrokePath
init<T>(controlPoints: T, creationDate: Date) where T: Sequence, T.Element == PKStrokePoint
// PKStroke (UIKit)
init(ink: PKInk, path: PKStrokePath, transform: CGAffineTransform = .identity, mask: UIBezierPath? = nil)
```

Fuentes: [punto](https://developer.apple.com/documentation/pencilkit/pkstrokepoint-swift.struct/init(location:timeoffset:size:opacity:force:azimuth:altitude:)), [trayectoria](https://developer.apple.com/documentation/pencilkit/pkstrokepath-swift.struct/init(controlpoints:creationdate:)), [trazo](https://developer.apple.com/documentation/pencilkit/pkstroke-swift.struct/init(ink:path:transform:mask:)-1imp6). Los puntos sintéticos son datos de prueba; su `force` no representa presión medida del dedo en un iPhone. Comparar el render antes/después de restaurar la misma fuente no presupone estabilidad de píxeles entre versiones diferentes del sistema.

### Guardar y restaurar

El modelo guarda los elementos mixtos en su representación nativa. Las firmas verificadas son:

```swift
func dataRepresentation() async throws -> Data
init(dataRepresentation: Data) throws
```

Fuentes: [serialización](https://developer.apple.com/documentation/paperkit/papermarkup/datarepresentation()), [restauración](https://developer.apple.com/documentation/paperkit/papermarkup/init(datarepresentation:)). El callback [`paperMarkupViewControllerDidChangeMarkup`](https://developer.apple.com/documentation/paperkit/papermarkupviewcontroller/delegate-swift.protocol) permite detectar cambios.

La documentación Markdown de [`indexableContent`](https://developer.apple.com/documentation/paperkit/papermarkup/indexablecontent) declara disponibilidad desde iOS 26.0 y la firma `var indexableContent: String? { get async }`. Permite consultar el contenido textual indexable para complementar las comprobaciones del roundtrip. Por sí sola no demuestra preservación de estilo, posición ni equivalencia visual; las nuevas comprobaciones que la incorporan todavía necesitan su propia ejecución de CI.

Decisión de implementación del proyecto: tomar una copia del modelo y su revisión antes de serializar/renderizar; publicar fuente y derivados de esa misma revisión, con control de orden de escrituras. Un `Task` nuevo en cada callback sin ese control permitiría que terminara primero una revisión más reciente y luego se sobrescribiera con otra vieja.

### Render y compatibilidad

[`draw(in:frame:options:)`](https://developer.apple.com/documentation/paperkit/papermarkup/draw(in:frame:options:)) dibuja el modelo completo en el `CGContext` suministrado y es asíncrono:

```swift
await markup.draw(in: context, frame: canvas)
```

El adaptador crea un contexto bitmap explícito con sRGB, SDR, fondo blanco y dimensiones de salida. Antes de dibujar aplica al contexto una transformación explícita entre las coordenadas del lienzo y los píxeles de salida, incluida la inversión vertical; `frame` conserva los límites lógicos del lienzo. Esto corrigió el recorte observado al producir los derivados. No se debe colocar `await` dentro del closure síncrono de `UIGraphicsImageRenderer.image`.

**Evidencia observada:** en la ejecución `37221416769`, sobre un iPhone 16e con runtime iOS 26.2, pasó el rechazo de fuente PaperKit corrupta. En el roundtrip mixto pasaron las comprobaciones de presencia en las regiones de texto, imagen y trazo; falló solamente la igualdad exacta de píxeles. Los adjuntos `mixed-note-before` y `mixed-note-restored` se inspeccionaron y muestran los tres elementos completos. El diagnóstico de esos PNG identificó los mismos 1287 píxeles de texto desplazados un píxel hacia abajo tras restaurar (`dy = +1`); imagen y trazo fueron idénticos, sin otras diferencias. Es una observación de este fixture y runtime, no una garantía general de PaperKit. La comparación refinada está pendiente de ejecutar; esta ejecución conserva su resultado fallido.

La orientación de fotos reales, fidelidad de color, alfa y correspondencia con la vista interactiva siguen pendientes de validación en simulador o iPhone. La inspección de los PNG generados no demuestra por sí sola esas conductas.

[`FeatureSet.isSubset(of:)`](https://developer.apple.com/documentation/paperkit/featureset/issubset(of:)) permite contrastar las funciones del documento con las del editor. Guardar un render junto a la fuente permite mostrar sólo la imagen si la fuente no se abre o no es compatible. Esta estrategia se recomienda en [Meet PaperKit](https://developer.apple.com/videos/play/wwdc2025/285/). No eliminar silenciosamente elementos incompatibles para poder sobrescribir el documento.

## iOS 27: fuentes existentes, implementación posterior

[Unwrap PaperKit, WWDC26](https://developer.apple.com/videos/play/wwdc2026/372/) está disponible y describe `subelements`, `MarkupOrderedSet`, elementos concretos y `allowedInteractions` en iOS 27. [Read between the strokes with PencilKit, WWDC26](https://developer.apple.com/videos/play/wwdc2026/203/) también está disponible y presenta reconocimiento local de escritura y APIs nuevas de trazos en iOS 27. La sesión advierte diferencias de idiomas entre simulador y dispositivo.

Estas fuentes del plan se corroboraron. M0/base M1 conserva iOS 26 como mínimo y no incorpora esas mejoras. Una futura implementación necesita tanto comprobaciones de disponibilidad en ejecución como un SDK que declare los símbolos; `if #available` por sí solo no incorpora APIs ausentes de un SDK anterior.

La [tabla oficial de Xcode](https://developer.apple.com/xcode/system-requirements) consultada enumera Xcode 27 con SDK iOS 27 y requisito macOS Tahoe 26.6 o posterior. Es información del producto publicado por Apple; no significa que ese software esté instalado en el entorno del repositorio. La versión efectiva debe registrarse con `xcodebuild -version` y `xcodebuild -showsdks` en el Mac de validación.

## Widget local y App Group

La [guía de creación de Widget Extensions](https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension) documenta un target separado, `StaticConfiguration`, `TimelineProvider`, `TimelineEntry`, `WidgetBundle` y `widgetURL`. El primer experimento puede leer un snapshot local y solicitar una recarga al guardar. Hay que abrir la app al menos una vez después de instalarla para que su widget aparezca en la galería.

Para compartir archivos, app y extensión deben pertenecer al mismo App Group y obtener el contenedor con `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`. Apple requiere registrar los App Groups de iOS; configurar una cadena de ejemplo no concede el entitlement ni demuestra que funcione en un dispositivo. Fuentes: [configuración de App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups), [acceso al contenedor](https://developer.apple.com/documentation/foundation/filemanager/containerurl(forsecurityapplicationgroupidentifier:)).

Decisión del experimento: la extensión consume un render y metadatos mínimos, nunca el documento editable completo. Si falta el contenedor configurado, debe mostrar un estado explícito y la app debe informar que compartir el render no está disponible; no simular un guardado compartido con un directorio privado distinto.

## Riesgo de actualización y pruebas posteriores

[Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date) explica que la extensión no permanece activa y que las recargas tienen presupuesto dinámico. Una llamada de recarga no permite prometer actualización inmediata. La antigüedad visible debe depender del snapshot.

[Updating widgets with WidgetKit push notifications](https://developer.apple.com/documentation/widgetkit/updating-widgets-with-widgetkit-push-notifications) documenta `WidgetPushHandler`, su token y `.pushHandler(...)`. El servidor usa APNs con tipo `widgets`, topic terminado en `.push-type.widgets` y `aps.content-changed`. La entrega es oportunista y presupuestada; complementa las timelines. Un token FCM de la app no demuestra que se haya configurado el token de WidgetKit. [What’s new in widgets, WWDC25](https://developer.apple.com/videos/play/wwdc2025/278/) confirma ese comportamiento.

Push remoto queda como validación pendiente: requiere firma, capability, tokens y credenciales APNs legítimos, servidor de desarrollo y dispositivos. La prueba deberá cubrir app cerrada, reinicio, red ausente, render viejo, recuperación y presupuestos reales. El modo de desarrollo de WidgetKit puede omitir presupuestos y por eso no acredita fiabilidad de producción. No se envió ningún push ni se configuró una cuenta durante esta investigación.

## Salida verificable del experimento en Mac

1. Registrar macOS, Xcode, SDK y destino; compilar app y Widget Extension.
2. Crear texto editable, foto e ink con dedo; guardar y cerrar la app.
3. Reabrir, mover/editar los objetos y comprobar trazos. Volver a guardar.
4. Comparar render antes/después de restaurar y verificar orientación/color/tamaño en una composición asimétrica.
5. Mostrar en widget local el derivado de la revisión guardada mediante el App Group; comprobar placeholder y deep link.
6. Repetir con documento corrupto/incompatible, contenedor ausente y escrituras fuera de orden.

La compilación del punto 1 está acreditada por la ejecución enlazada con SDK 26.0; ejecutar sobre el runtime mínimo 26.0 sigue pendiente. También hay evidencia parcial del punto 4 para el fixture y del rechazo de fuente corrupta del punto 6, detallada arriba. La suite nativa completa, la interacción manual, App Group/widget visible y las demás condiciones conservan sus pendientes; la investigación documental no las marca como aprobadas.
