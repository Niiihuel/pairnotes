# App de notas en pareja para iOS — Plan de producto e implementación

**Nombre técnico provisional:** PairNotes. **Investigación:** 4 de octubre de 2026.
**Estado:** especificación para desarrollar con Codex; no es una aplicación ya construida ni validada en dispositivos.

## 1. Objetivo y decisiones principales

Crear una aplicación privada para dos personas: escribir notas, dibujar, añadir fotos y stickers, enviarse creaciones, conservar un timeline y ver la última nota recibida en un widget. Además, un segundo widget de pantalla de bloqueo mostrará las dos fotos de perfil y la distancia aproximada entre los dispositivos autorizados.

La arquitectura propuesta es **Swift + SwiftUI + UIKit, PaperKit/PencilKit para las notas, un motor Metal posterior para pintura avanzada, WidgetKit, Core Location y Firebase**. La aplicación iOS será nativa. Las funciones de servidor propuestas son TypeScript; esto no convierte la aplicación en híbrida.

Decisiones de partida:

| Tema | Decisión propuesta |
|---|---|
| Plataforma | iPhone primero; diseño adaptable a iPad, sin exigir Apple Pencil. |
| Sistema mínimo | iOS 26.0; mejoras de iOS 27 detrás de comprobaciones de disponibilidad. |
| Editor inicial | PaperKit para combinar dibujo, texto, formas e imágenes. |
| Pintura avanzada | Documento y motor raster propios, desarrollados por etapas. |
| Identidad | Google como acceso principal solicitado; añadir Sign in with Apple. |
| Relación | Un espacio activo de dos integrantes, unión por invitación aceptada. |
| Nube | Firebase Auth, Firestore, Storage, Functions, App Check y notificaciones. |
| Persistencia local | SwiftData para índices/borradores y archivos para documentos/imágenes. |
| Widgets | Nota en pantalla de inicio; distancia y fotos en pantalla de bloqueo. |
| Ubicación | Consentimiento independiente, bajo consumo, sin historial de recorridos. |
| Publicación | Notas enviadas inmutables; editar una copia crea una nueva nota. |
| Distribución inicial | Pruebas en dos iPhones físicos y TestFlight. |

El mínimo iOS 26 evita mantener un editor alternativo antiguo: PaperKit apareció en esa versión. iOS 27 añade acceso programático más amplio a elementos, y nuevas capacidades de PencilKit que se aprovecharán sin romper la compatibilidad mínima. [S02][S03][S04]

**Límite esencial:** “distancia siempre visible” es viable como última distancia disponible; “ubicación exacta y widget actualizado cada segundo, las 24 horas” no es una promesa que pueda hacerse en iOS. La interfaz debe distinguir datos recientes, antiguos, pausados y no disponibles. Los mecanismos de ubicación y de actualización del widget tienen ciclos de vida y restricciones propios. [S06][S08][S09]

## 2. Experiencia de usuario

### 2.1 Recorrido principal

Al abrir por primera vez, la persona inicia sesión, elige nombre y foto, y crea o acepta una invitación. Hasta vincularse puede dibujar y guardar borradores privados, pero no enviar a una pareja inexistente. Vincular cuentas no activa automáticamente notificaciones, fotos ni ubicación.

La navegación tendrá cuatro áreas: **Inicio**, **Crear**, **Recuerdos** y **Nosotros**. Inicio mostrará la última nota recibida, el acceso a enviar una nueva y una tarjeta de distancia cuando exista consentimiento. Recuerdos será el timeline compartido. Nosotros contendrá los dos perfiles, permisos, widgets, configuración y desvinculación.

El editor debe abrir rápido en un lienzo preparado, no en un panel profesional lleno de controles. Primero se muestran bolígrafo, borrador, color, texto, foto y deshacer. Herramientas adicionales se organizan en paneles contextuales. La complejidad avanzada no debe impedir escribir una nota de diez segundos.

### 2.2 Funciones de la primera versión utilizable

La primera versión completa debe permitir iniciar sesión, vincular dos cuentas, crear una composición mixta, guardar un borrador sin conexión, enviar con reintentos, recibir una notificación, consultar el historial, colocar el widget de nota, configurar fotos y compartir distancia opcionalmente. El widget de bloqueo forma parte del objetivo inicial del producto, no queda descartado por construir primero las notas.

Favoritos, una reacción sencilla y fijar una nota en el widget son ampliaciones próximas. Comentarios extensos, chat independiente, grupos, feed público y dibujo colaborativo simultáneo quedan fuera del alcance inicial.

### 2.3 Reglas de las notas y del timeline

Cada nota enviada conserva autor, destinatario, fecha de servidor, identificador de documento y versiones de sus imágenes. Una nota recibida se puede guardar como favorita o copiar a un nuevo borrador; no se modifica silenciosamente el original. “Vista” solo significa que el destinatario abrió su detalle dentro de la aplicación, no que un proceso del widget descargó una imagen.

El timeline ordena por fecha de publicación del servidor y usa paginación por cursor. La tarjeta muestra una miniatura, no el archivo editable completo. Los borradores no pertenecen al timeline compartido. La opción de respaldar borradores en la nube, cuando se implemente, debe usar un espacio privado separado.

## 3. Investigación de ibisPaint X aplicada al producto

Los manuales oficiales muestran que ibisPaint combina herramientas de dibujo, selección, capas, transformación y efectos. La aplicación propuesta tomará esas familias funcionales como referencia, no copiará sus recursos, interfaz exacta ni formatos propietarios. Los parámetros de pincel y de relleno merecen diseños separados: no se resuelven agregando más botones a PencilKit. [S11][S12][S13][S14]

**Prioridades:** P0 = versión de notas y widgets; P1 = expansión creativa; P2 = estudio avanzado; P3 = opcional o de bajo valor para este producto. La tabla es una propuesta de implementación, no una afirmación de que todas las funciones sean nativas de Apple.

| Familia | Herramientas a ofrecer | Implementación propuesta | Prioridad |
|---|---|---|---|
| Dibujo cotidiano | Bolígrafo, lápiz, marcador, borrador, grosor y color | PaperKit/PencilKit; controles compatibles con el tipo de tinta real | P0 |
| Navegación | Zoom, desplazar, rotar vista, recentrar; atajos de deshacer/rehacer | Gestos del canvas y botones accesibles; evitar conflictos de reconocimiento | P0 |
| Color | Paletas propias, recientes, HEX, opacidad y cuentagotas | Estado de estilo de la app; muestrear el resultado visible del render | P0–P1 |
| Texto | Cajas editables, tipografía, tamaño, alineación, color | Elementos nativos; estilos especiales como extensión propia | P0 |
| Fotos y collage | Insertar varias fotos, mover, rotar, escalar, recortar | PhotosPicker, PaperKit y pipeline de imagen | P0 |
| Formas | Líneas, flechas, rectángulos, elipses, corazones y bocadillos | Elementos nativos donde estén disponibles; recursos propios para el resto | P0–P1 |
| Stickers y fondos | Recortes de fotos, marcos, papel, sellos, patrones | Imágenes transparentes propias, originales o con licencia | P0–P1 |
| Corrección de fotos | Brillo, contraste, saturación, temperatura, desenfoque | Operaciones no destructivas; Core Image y render de resultado | P1 |
| Recorte de sujetos | Separar persona/objeto del fondo y convertir en sticker | Vision/VisionKit; revisar resultado y permitir corregir/cancelar | P1 |
| Organización de objetos | Orden, duplicar, borrar, bloquear y transformar | API de elementos de PaperKit en iOS 27; degradación explícita en 26 | P1 |
| Capas raster | Crear, nombrar, reordenar, duplicar, ocultar, opacidad, fusionar y grupos | Documento Studio y compositor propios | P1–P2 |
| Relleno | Cubeta, tolerancia, cerrar huecos, referencia de capa o composición | Algoritmo flood fill/máscara; no confundir con rellenar una forma | P2 |
| Selección de píxeles | Lazo, rectángulo, elipse, varita, rango de color, invertir, expandir/contraer | Motor de máscaras; el lazo nativo de trazos no cubre esto | P2 |
| Composición avanzada | Alpha lock, clipping, máscaras de capa y selección | Grafo de composición y máscaras propias | P2 |
| Fusión | Normal, multiply, screen, overlay y modos adicionales comprobados | Composición con alfa premultiplicado y pruebas de referencia | P2 |
| Pinceles personalizados | Punta, separación, dispersión, textura, variación, inicio/final y estabilizador | Motor de sellos/trazos en Metal; presets versionados y semilla reproducible | P2 |
| Dinámica | Tamaño/opacidad según velocidad o presión; inclinación cuando exista | Datos de entrada reales; no simular presión como si fuera medida en iPhone | P2 |
| Guías | Regla, simetría espejo, radial, cuadrícula y perspectiva | Transformaciones de puntos, snapping y overlays propios | P1–P2 |
| Transformación avanzada | Perspectiva, deformación de malla y curvas editables | Matrices, malla y herramientas vectoriales del motor | P2–P3 |
| Efectos | Curvas, niveles, mapas de degradado, contorno, sombra, glow, ruido y mosaico | Grafo no destructivo; Core Image o shaders según el efecto | P1–P2 |
| Pintura especial | Smudge, blur localizado, clonar, mezclar color, licuar | Operaciones sobre textura y memoria temporal; alto costo técnico | P2–P3 |
| Escritura inteligente | Reconocer texto manuscrito y buscar notas por su contenido | Mejora iOS 27 con PencilKit; habilitación y resultados revisables | P1 |
| Replay | Reproducir cómo se creó una nota y exportar video | Registro de operaciones propio y AVFoundation | P3 |
| Exportación profesional | PSD, CMYK, manga, impresión multipágina | Fuera del primer producto; no prometer equivalencia de formatos | P3 |

La selección inicial ya permite notas muy completas. El objetivo posterior puede acercarse a un estudio de pintura, pero no conviene frenar autenticación, envío y widgets hasta haber escrito un motor equivalente a una aplicación profesional.

## 4. Arquitectura del editor

### 4.1 Editor nativo de notas

Usar `PaperMarkupViewController` integrado en SwiftUI mediante un adaptador UIKit. `PaperMarkup` es el documento de composición; el sistema nativo aporta dibujo y objetos mixtos. La primera prueba debe cubrir insertar imagen/texto/trazos, guardar, volver a cargar y generar una imagen final. [S02]

En iOS 27, la nueva colección `subelements` y las interacciones configurables por elemento permiten ampliar la selección, el bloqueo y los controles propios. Estas mejoras deben vivir en un adaptador con disponibilidad comprobada, no dispersas por todo el código. [S03]

PencilKit iOS 27 ofrece reconocimiento de escritura en el dispositivo y nuevas operaciones sobre trazos. Es una vía para buscar recuerdos escritos a mano, no un requisito para mandar una nota básica. La compatibilidad lingüística y las diferencias entre simulador y dispositivo se comprueban antes de activar esa mejora. [S04]

Un elemento personalizado de la paleta de PencilKit permite integrar una herramienta propia, pero no implementa por sí mismo su algoritmo de dibujo. Se evita inventar una supuesta API nativa de cubeta, smudge o pinceles ibisPaint. [S05]

### 4.2 Studio: motor avanzado separado

Crear después `StudioCanvasEngine` sobre Metal, con documento `studio-v1`. La primera entrega del motor solo necesita pincel, borrador, dos capas, composición, guardado y exportación. Luego se agregan máscaras, cubeta y pinceles personalizados en tareas distintas.

Habrá dos tipos editables de nota: `paper-v1` y `studio-v1`. Ambos comparten envío, timeline, fotos de perfil y widgets mediante una imagen renderizada normalizada. En la primera integración **no se promete conversión reversible** entre los dos motores: importar una composición como imagen conserva su apariencia, no recupera capas o trazos originales.

Más adelante un dibujo Studio puede insertarse como elemento gráfico en una nota nativa. Debe conservarse su fuente editable como adjunto vinculado; volver a editarlo requiere abrir ese adjunto y sustituir su previsualización. Es una integración adicional, no una capacidad implícita de PaperKit.

### 4.3 Formato y persistencia

El contenedor lógico `NoteDocument` incluye `schemaVersion`, `editorKind`, `minimumEditorVersion`, `canvasSize`, `colorSpace`, identificadores de activos y hash de revisión. El payload nativo se conserva como bytes del formato de Apple; el de Studio guarda manifiesto propio, capas, operaciones y bloques de píxeles.

Por cada nota se producen: fuente editable, imagen final, imagen de widget y miniatura. Una imagen final no reemplaza el documento editable. Un dispositivo incapaz de abrir una versión nueva mostrará la imagen en modo de solo lectura. Nunca debe intentar guardar encima de una fuente incompatible.

Propuesta inicial: lienzo cuadrado de 1536 px, opción 2048 px tras medir rendimiento, sRGB/SDR y fondo configurable. Generar miniatura de aproximadamente 320–480 px y derivado de widget adaptado a sus puntos y escala, normalmente hasta 1024 px. Son presupuestos iniciales de producto, no límites del sistema.

Todos los formatos pasan por un contrato único de orientación, recorte, fondo, alfa y perfil de color. El resultado de la pantalla, el timeline y el widget debe corresponder a la misma revisión.

### 4.4 Historial y rendimiento

El guardado automático usa revisiones monotónicas y escrituras atómicas. Una serialización antigua no puede sobrescribir otra nueva aunque termine después. El historial incluye texto, imágenes, filtros y transformaciones, no solamente trazos. Cuando el editor nativo controla una operación, su historial se integra o delimita explícitamente; no se duplican cambios entre dos gestores de undo.

Una capa RGBA de 2048 × 2048 × 4 bytes ocupa 16 MiB sin comprimir. Doce capas implican unos 192 MiB antes de texturas duplicadas e historial. Por eso Studio requiere tiles, límites adaptativos, snapshots/deltas comprimidos y procesamiento fuera del hilo principal; no “capas infinitas”. Este cálculo es un presupuesto de ingeniería, no una medición del motor futuro.

Diseñar para el dedo en iPhone. El soporte de presión, inclinación o controles Apple Pencil solo se activa en dispositivos y accesorios compatibles. No debe ser indispensable para ninguna función central.

## 5. Frameworks y componentes

La siguiente selección reduce dependencias sin confundir un framework con una solución completa. Las integraciones de canvas, fotos, recorte de sujetos, widgets y ubicación se apoyan en ejemplos oficiales. [S02][S05][S06][S08][S09][S15][S16]

| Necesidad | Componente y responsabilidad propuesta |
|---|---|
| Interfaz | SwiftUI, Observation y UIKit únicamente donde las APIs lo requieran. |
| Dibujo y objetos | PaperKit/PencilKit; motor Metal posterior, separado por protocolo. |
| Texto y geometría propios | Core Text, Core Graphics y formatos de estilo de la app. |
| Imágenes | PhotosUI/PhotosPicker, Transferable, ImageIO; Core Image para operaciones. |
| Sujetos sin fondo | Vision/VisionKit; procesamiento local cuando se use esta ruta. |
| GPU | Metal/MetalKit para motor de pintura y composiciones complejas. |
| Datos locales | SwiftData para metadatos; FileManager para binarios; no imágenes enormes en registros. |
| Concurrencia | Swift Concurrency, actors para outbox/caché/documentos; UI en MainActor. |
| Widgets | WidgetKit, SwiftUI, App Intents para configuración y App Groups para snapshots. |
| Identidad | Google Sign-In iOS, Firebase Auth, AuthenticationServices para Apple. |
| Seguridad local | Keychain y grupos de acceso explícitos para credenciales limitadas. |
| Avisos | UserNotifications, APNs y FCM para la notificación ordinaria. |
| Distancia | Core Location y servicio de cálculo derivado en el backend. |
| Mantenimiento | BackgroundTasks para trabajo oportunista, nunca como cron exacto. |
| Exportaciones futuras | AVFoundation para video, compartir del sistema para imágenes. |
| Calidad | Swift Testing, XCTest/XCUITest, Instruments, OSLog con privacidad y métricas agregadas. |

Bibliotecas externas opcionales: **TOCropViewController** para recortar imágenes; **Nuke** para carga/caché autenticada fuera de la extensión; **MetalPetal** para procesamiento de imagen en GPU. Ninguna equivale a un editor completo. Antes de agregarlas se debe comprobar licencia, plataformas, mantenimiento y fijar versiones con Swift Package Manager. [S25][S26][S27]

## 6. Nube, autenticación y vinculación

### 6.1 Por qué Firebase

Firebase concentra identidad, documentos, almacenamiento y funciones operativas en una integración razonable para un equipo pequeño. Google y Apple disponen de rutas documentadas para Firebase Auth. Firestore aporta caché offline de documentos, pero hay que implementar aparte los archivos y la cola de envío. [S17][S18][S19]

No usar CloudKit como base principal de este diseño: se busca identidad Google y relación explícita entre cuentas del producto. Tampoco hace falta desplegar simultáneamente Supabase, un servidor propio y Firebase. Elegir una sola fuente de verdad evita sincronizaciones redundantes.

La configuración propuesta usa Functions en TypeScript para operaciones privilegiadas. Swift sigue siendo el lenguaje de todos los targets iOS. Un backend completamente Swift con Vapor sería otra arquitectura posible, pero no debe introducirse al mismo tiempo que Functions sin una necesidad concreta. [S28]

### 6.2 Google y Apple

Mantener “Continuar con Google”. Para una aplicación de consumo publicada en App Store que lo utilice como acceso principal, la regla 4.8 exige una opción equivalente con determinadas características de privacidad, salvo excepciones. Añadir Sign in with Apple es la decisión práctica propuesta; no se afirma que la norma prohíba Google. [S20]

La identidad interna será el UID de Firebase. No vincular cuentas automáticamente porque coincida un correo, una foto o un nombre; enlazar proveedores requiere un flujo autenticado y resolución de conflictos. Implementar sesión cancelada, revocada, restaurada y reautenticación para operaciones sensibles.

### 6.3 Pareja

El servidor crea una invitación opaca con entropía suficiente, guarda su hash y registra caducidad. Propuesta: URL con token aleatorio de al menos 128 bits; código manual alternativo de un solo uso y fuertemente limitado por intentos. TTL inicial de invitación: 15 minutos, ajustable.

La aceptación es transaccional: ambas cuentas deben ser elegibles, distintas y no estar en otra pareja activa. La pareja admite como máximo dos miembros. Conocer el ID no autoriza a leerla. El backend controla integrantes, estado y `pairEpoch`, una generación que invalida trabajo antiguo al cerrar la relación.

Cada integrante acepta compartir ubicación por separado. La invitación no concede acceso a coordenadas. Compartir ubicación, aceptar notificaciones y aparecer en widgets son controles independientes.

## 7. Datos y publicación robusta

Firestore conserva metadatos y permisos. Storage conserva fotos, fuentes y renders. No guardar el contenido binario en Base64 dentro de Firestore. Las reglas de ambos servicios y la autorización de los endpoints deben ser parte del desarrollo, no un arreglo posterior. App Check suma protección contra abuso; no sustituye la verificación de pertenencia. [S21][S22]

Modelo lógico:

```text
users/{uid}                         perfil privado y preferencias
users/{uid}/devices/{deviceId}       tokens y dispositivo de ubicación elegido
pairs/{pairId}                      miembros, estado, pairEpoch
pairs/{pairId}/profiles/{uid}        nombre/foto visibles dentro de la pareja
pairs/{pairId}/notes/{noteId}        publicaciones inmutables
pairs/{pairId}/views/{uid}           última nota recibida / fijada
pairs/{pairId}/distance/current     distancia derivada, precisión y antigüedad
locationPrivate/{uid}               última coordenada: solo servidor
pairInvites/{inviteHash}            invitaciones: solo servidor
uploadSessions/{uploadId}           publicación en progreso: solo servidor
widgetSessions/{sessionId}          credencial y alcance: solo servidor
```

Esto describe colecciones propuestas, no reglas ya desplegadas. Los contratos y permisos campo por campo están en `ARQUITECTURA_Y_CONTRATOS.md`.

### Protocolo de envío

1. Persistir localmente el borrador y una operación con `idempotencyKey`.
2. Capturar una revisión consistente y generar todos sus derivados.
3. Solicitar una sesión de carga autorizada; subir a un prefijo temporal privado.
4. Validar tamaño, tipo, pertenencia, integridad y existencia de activos.
5. Congelar/copiar activos a rutas inmutables y confirmar metadatos en una transacción.
6. Actualizar el puntero de última nota del destinatario y registrar eventos de notificación.
7. Enviar avisos y señales de widget con reintentos independientes.

No existe una transacción única que abarque por arte de magia el almacenamiento de archivos y el documento de publicación. Por eso hay sesión de carga, finalización idempotente y limpieza de huérfanos. Un reintento devuelve la nota existente; no crea otra. Un archivo temporal nunca aparece en el timeline de la pareja.

La app muestra “Guardado en este iPhone”, “En cola”, “Enviando”, “Enviado” o “No se pudo enviar”. No muestra “Enviado” por haber terminado solamente el upload. La notificación llega después de que los activos publicados sean accesibles al destinatario.

## 8. Widget de notas

### 8.1 Presentación

Un `NoteWidget` pequeño muestra la creación y una identificación mínima del autor. La variante mediana puede añadir foto, fecha y un poco más de contexto. El usuario elige última nota recibida o una nota fijada. Tocar el widget abre el detalle autorizado; no abre un editor dentro de la pantalla de inicio.

El usuario debe colocar el widget desde la interfaz del sistema. La app proporciona un tutorial y detecta/configura estados, pero no promete instalarlo por sí sola. [S30]

### 8.2 Actualización

La extensión consume un snapshot compacto, no carga todo el historial ni mantiene una conexión Firestore permanente. La app y la extensión comparten JSON e imágenes reducidas mediante App Groups. Los secretos van en Keychain con alcance limitado, no en `UserDefaults` compartido.

Desde iOS 26 existe la actualización push de WidgetKit. Se registra el token específico del widget y se envía la señal por APNs según el mecanismo oficial. Es distinta de la notificación FCM de la app y sigue siendo oportunista: no constituye un compromiso de actualización instantánea. [S06]

Flujo propuesto:

```text
Publicación confirmada
  → evento de backend
  → aviso normal al destinatario
  → señal push de WidgetKit
  → ejecución autorizada del provider por iOS
  → obtener snapshot y derivados de imagen
  → reemplazo atómico de la caché
  → nueva entrada visible del widget
```

El provider obtiene los bytes de red antes de producir la entrada; la vista del widget no confía en una descarga arbitraria disparada por `body`. Debe soportar no tener conexión, credencial vencida, caché incompleta y token renovado. La solicitud de recarga desde la app es otra vía de recuperación, no garantía de ejecución inmediata.

## 9. Widget de distancia con fotos

### 9.1 Diseño y alcance

Implementar `DistanceWidget` con familia `accessoryRectangular`: foto circular A, elemento gráfico de unión, foto circular B, distancia y estado. Una variante `accessoryInline` será de texto. Una `accessoryCircular` deberá simplificarse; intentar colocar dos fotos y mucha información en ese espacio reduce la legibilidad.

El widget de bloqueo de la referencia se interpreta como inspiración de composición. iOS aplica modos de representación propios: en la pantalla de bloqueo las fotos pueden verse desaturadas o teñidas. Se conserva la composición y la identificación, pero no se promete color completo en cualquier tema. La app y una variante de inicio pueden mostrar las fotografías a color cuando el modo del sistema lo permita. [S07]

Las fotos son perfiles personalizados, importados y procesados por la aplicación, no enlaces permanentes dependientes de Google. Cambiarlas incrementa su revisión y actualiza las cachés. Las notitas y la distancia se pueden colocar como widgets independientes.

### 9.2 Qué distancia se calcula

La distancia inicial es geográfica en línea recta entre las últimas dos posiciones válidas; no es distancia de ruta ni tiempo de viaje. El backend recibe una muestra por integrante y publica únicamente una distancia derivada. No se necesita mostrar un mapa o entregar coordenadas al otro usuario.

El formato usa redondeo apropiado y la palabra “aproximadamente” cuando corresponda. Si la precisión es demasiado pobre para distinguir cercanía, se muestra “No se puede estimar con esta precisión”, no “Están juntos”. La suma de errores de posición es una señal conservadora de incertidumbre, no una garantía estadística absoluta.

### 9.3 Ubicación y batería

Configurar una política de ubicación única. Al entrar en la función, solicitar permiso contextual. Empezar por “Al usar la app”; solicitar el acceso de fondo que corresponda solo después de que la persona active explícitamente compartir en segundo plano. Respetar ubicación aproximada y permitir seguir usando las notas si se deniega todo acceso. [S08]

**Modo predeterminado:** refresco al abrir y servicio de cambios significativos para movimiento de bajo consumo. **Modo activo opcional:** una sesión visible y limitada, por ejemplo “Compartir mientras nos encontramos”, usando los mecanismos modernos de Core Location, con finalización explícita y automática. No mantener precisión de navegación permanentemente. Las APIs modernas de actualizaciones y sesiones sirven para coordinar el ciclo de vida; no eliminan las condiciones del sistema. [S09][S10]

Elegir un iPhone como fuente activa de ubicación por cuenta. Una sesión del mismo usuario en un iPad inmóvil no debe sobrescribir la posición del teléfono. Registrar `sourceDeviceId`, secuencia, momento de medición, recepción y versión de consentimiento; rechazar muestras antiguas, futuras de forma inverosímil o de un dispositivo ya revocado.

El widget no realiza seguimiento GPS continuo. Recibe el estado derivado; la app administra la localización. No diseñar un timer de fondo que prometa ejecutarse cada minuto.

### 9.4 Estados y antigüedad

La frescura depende de la posición **más antigua de las dos**, no de cuándo el servidor recalculó el número. Actualizar la posición de A no convierte una posición vieja de B en reciente.

Configuración inicial de producto, a medir y ajustar:

| Estado | Regla propuesta | Presentación |
|---|---|---|
| Reciente | Ambas muestras válidas y con edad máxima de 15 min | Distancia aproximada y acceso al detalle de actualización |
| Antigua | La más antigua tiene entre 15 y 60 min | Última distancia con aviso visible de antigüedad |
| No disponible | Falta alguna muestra válida o supera 60 min | “Sin ubicación reciente”; no inventar un número actual |
| Pausada | Alguno retiró consentimiento | “Compartir ubicación pausado” |
| Imprecisa | La incertidumbre supera el nivel admitido | Distancia aproximada menos precisa o aviso de precisión insuficiente |
| Desvinculada | Pareja cerrada o cambió `pairEpoch` | Estado genérico sin datos compartidos |

Quince y sesenta minutos son decisiones de interfaz, **no una frecuencia garantizada de GPS**. El servicio pasivo puede producir muestras menos frecuentes si el teléfono no detecta cambios. Se prioriza mostrar antigüedad honesta antes que gastar batería solo para renovar una etiqueta.

El snapshot contiene `validUntil` y futuras entradas para degradar su estado. También muestra una hora/edad comprensible: si iOS retrasa una ejecución, no debe quedar una frase absoluta de “en vivo”. Al abrir la aplicación se reconcilia todo con el servidor.

### 9.5 Extensiones opcionales y límites

Una Location Push Service Extension es una investigación independiente, no requisito del MVP ni solución garantizada a actualizaciones continuas. La documentación y el proceso de su entitlement presentaban una discrepancia reconocida en el foro oficial de Apple en agosto/septiembre de 2026. Antes de adoptarla hay que validar capacidad, provisión y comportamiento real; este plan no da por aprobado un permiso especial. [S29]

Una Live Activity podría servir para un encuentro temporal, pero no reemplaza un widget permanente ni concede permisos de localización adicionales. Cierre forzado, ausencia de red, batería y restricciones del sistema deben traducirse a estados honestos, no intentos de eludir iOS.

## 10. Privacidad y seguridad

Por defecto se conserva solo la última muestra de ubicación por persona, sin recorridos ni mapa de visitas. Política inicial propuesta: máximo 24 horas de retención de coordenadas crudas para el servicio; al pausar se borran. La caducidad se hace valer en las consultas aunque la limpieza física asíncrona se retrase.

El servidor conoce las coordenadas necesarias para calcular distancia. La propuesta inicial utiliza controles de acceso, transporte protegido y almacenamiento protegido, pero **no se presenta como cifrado de extremo a extremo**. Introducir E2EE requeriría otro diseño de claves, recuperación, dispositivos y cálculo de distancia.

No incluir coordenadas, contenido íntimo o URLs privadas en notificaciones, analítica o logs. Quitar metadatos GPS/EXIF de las imágenes que se compartan. El destinatario solo accede a fotos, notas y distancia autorizadas, nunca a documentos de tokens, invitaciones o coordenadas.

Las imágenes no se publican mediante URLs eternas accesibles a cualquiera. Las descargas son autenticadas o usan enlaces temporales muy limitados. Para widgets, emitir una credencial revocable de solo lectura para su snapshot y derivados; nunca entregar una credencial administrativa o acceso al historial completo.

Pausar ubicación es inmediato en el dispositivo que lo solicita; el servidor confirma el cambio y bloquea nuevos datos. Sin red, detener localmente y mostrar “Pendiente de confirmar en el servidor”, sin fingir que el otro dispositivo ya se actualizó. Una desvinculación requiere confirmación del servidor para completarse.

Al desvincular, se cierra el espacio compartido y se invalidan tokens/consentimientos. Se conserva el contenido creado por cada autor en su archivo privado según una política explícita; no se traslada automáticamente el contenido de la expareja a una relación nueva. El acceso compartido anterior se revoca. La implementación debe resolver archivo privado o eliminación, sin dejar documentos huérfanos accesibles.

Un dispositivo offline puede conservar una imagen antes autorizada. No se puede prometer borrado instantáneo de un widget ya representado, de capturas o de archivos que alguien exportó. Se borran las cachés controladas por la app al recibir revocación o al reconciliar la sesión.

Ofrecer eliminación de cuenta dentro de la aplicación, reautenticación y eliminación de activos propios mediante un trabajo verificable. La revisión de App Store incluye consentimiento y política de privacidad; una app privada no está exenta de esos puntos. [S20]

## 11. Estructura de código y ejecución con Codex

Estructura prevista —todavía no generada como proyecto Xcode—:

```text
PairNotes/
  App/                     ciclo de vida, dependencias, rutas
  Features/
    Auth/ Pairing/ Home/ Editor/ Timeline/ Couple/ Settings/
  Core/
    Domain/ Persistence/ Networking/ Media/ Security/
  Canvas/
    NativePaper/ Studio/ DocumentFormat/ Rendering/
  Widgets/
    NoteWidget/ DistanceWidget/ SharedSnapshot/
  Services/
    Publishing/ Location/ Notifications/ WidgetSync/
  Tests/
Backend/
  functions/ rules/ indexes/ tests/
docs/
```

Definir protocolos para identidad, repositorio de notas, publicador, proveedor de ubicación, renderizador y almacén del widget. Las vistas no hacen cargas a Storage ni cálculos de autorización. Los actors protegen trabajos concurrentes; la pertenencia real se valida siempre en el servidor.

Trabajar por cortes verticales: cada tarea termina en una conducta comprobable. El paquete incluye `AGENTS.md`, contratos, backlog, diseño y pruebas. Codex puede leer instrucciones de proyecto desde ese archivo; las tareas deben indicarle además el hito concreto y sus criterios de salida. [S31]

| Hito | Resultado verificable |
|---|---|
| M0 | Validar entorno, guardado/render nativo y riesgos de widget push en dispositivos. |
| M1 | App y extensión compilables, navegación, modelos puros y mocks. |
| M2 | Google/Apple y unión segura de dos cuentas; reglas contra acceso ajeno. |
| M3 | Crear nota mixta offline, guardar, reabrir y exportar misma revisión. |
| M4 | Publicación idempotente, imágenes privadas, timeline paginado y recepción. |
| M5 | Widget de nota con caché, deep link, push y credencial restringida. |
| M6 | Ubicación consentida, distancia correcta en la app y estados de antigüedad. |
| M7 | Widget de bloqueo con fotos y política de fondo medida en dos teléfonos. |
| M8 | Recortes, filtros, favoritos y mejoras nativas iOS 27. |
| M9 | Studio básico y expansiones por herramienta, con fixtures de render. |
| M10 | Accesibilidad, seguridad, consumo, recuperación y beta distribuible. |

No encargar “cloná ibisPaint y noteit completos” en una sola instrucción. Primero M0/M1, después identidad, editor, envío y widgets; el motor avanzado entra con su propio formato y pruebas.

## 12. Entorno de desarrollo

Como el flujo previo del usuario es NixOS/Linux, hay una condición importante: para compilar y ejecutar la app iOS y su simulador se necesita un entorno macOS con Xcode. Puede ser un Mac propio, remoto o un runner macOS; editar archivos en Linux no equivale a validar una compilación iOS. La tabla actual de Apple incluye Xcode 27 y sus requisitos de macOS. [S23]

El backend, especificaciones y partes Swift realmente independientes de Apple pueden desarrollarse y probarse en Linux. PaperKit, SwiftUI, firma, widgets y pruebas iPhone requieren las herramientas correspondientes. No usar EAS/Expo como sustituto de la cadena nativa Swift de este proyecto.

Antes de comenzar, registrar: Team ID, bundle identifiers de app y extensión, App Group, grupos Keychain, proyecto Firebase de desarrollo, cliente OAuth iOS, dominio/enlaces de invitación y credenciales APNs guardadas en secretos de servidor. No colocar claves privadas en el repositorio.

Dos dispositivos físicos son necesarios para validar sesiones separadas, notificaciones, ubicaciones, pantalla bloqueada, consumo y reanudación. El simulador sirve para mucha interfaz, pero no demuestra la fiabilidad real de la experiencia de pareja.

## 13. Costos y operaciones

Apple publica un precio de 99 USD por año de membresía para el Apple Developer Program, o moneda local donde corresponda. No se estiman aquí impuestos ni conversión a pesos argentinos. [S24]

Firebase exige el plan Blaze para Cloud Storage desde el cambio que entró en vigor el 3 de febrero de 2026. No diseñar la app suponiendo que las fotos quedarán para siempre en un plan Spark sin facturación. El consumo real depende de región, tráfico, funciones y volúmenes. [S32]

Ejemplo puramente hipotético: 10 notas totales al día a 4 MB medios entre fuente y derivados representan aproximadamente 14,6 GB nuevos por año, sin réplicas ni descargas. No es una medición ni un precio. El peso real debe medirse con fotos y dibujos de prueba.

Definir límites de tamaño y número de activos, cuotas por día, límites de intentos de invitación, limpieza de cargas abandonadas, control de egress y alertas de gasto. El endpoint de ubicación debe coalescer cambios; no escribir continuamente muestras redundantes. La caché y las miniaturas son parte del presupuesto, no solo de la velocidad.

Usar entornos separados de desarrollo y producción. Habilitar métricas de duración de publicación, errores de carga, antigüedad de snapshots y entrega de eventos sin registrar contenido personal. Registrar diferencias entre “push aceptado por APNs” y “usuario vio el widget”; no son la misma métrica.

## 14. Criterios de aceptación del producto

La aplicación queda lista para beta cuando dos cuentas reales pueden vincularse, enviar y recuperar una nota mixta conservando su fuente, verla en historial y widget, configurar las fotos y observar distancia consentida con antigüedad correcta. Una tercera cuenta debe ser incapaz de leer esos datos incluso con IDs conocidos.

Debe tolerar pérdida de red durante upload, pulsar enviar dos veces, cierre y reapertura, denegar permisos, sesión caducada, datos de ubicación desordenados y widgets con caché vieja. Pausar localización no rompe el envío de notas. Cambiar de pareja no mezcla imágenes ni permisos. El sistema más antiguo soportado ve una imagen de una nota nueva aunque no pueda editar su fuente.

La medición de batería y memoria, el comportamiento de push con la app cerrada, la firma y los límites prácticos del editor quedan como pruebas obligatorias de implementación. **Este documento entrega el plan y los contratos; no afirma que esas pruebas se hayan ejecutado.**

## 15. Orden recomendado para empezar

El primer objetivo real es una vertical pequeña: abrir la app, componer texto/foto/trazo, guardar, restaurar y mostrar el render en un widget local. En paralelo, preparar identidades y servidor de desarrollo. Ese experimento valida el corazón visual y el formato antes de construir muchas pantallas.

Después completar autenticación, pareja y publicación para que la misma creación cruce entre dos teléfonos. Luego integrar distancia y widget de bloqueo con todos sus estados. Finalmente ampliar las herramientas del editor por familias comprobadas.

Así se construye primero una aplicación que ustedes pueden usar, sin renunciar al editor avanzado ni basar la experiencia en promesas de segundo plano que iOS no garantiza.


## Referencias de este documento

Fuentes oficiales consultadas el 4 de octubre de 2026. El catálogo comentado está en `FUENTES.md`.

- **S02.** [Apple — Meet PaperKit, WWDC25](https://developer.apple.com/videos/play/wwdc2025/285/).
- **S03.** [Apple — Unwrap PaperKit, WWDC26](https://developer.apple.com/videos/play/wwdc2026/372/).
- **S04.** [Apple — Read between the strokes with PencilKit, WWDC26](https://developer.apple.com/videos/play/wwdc2026/203/).
- **S05.** [Apple — Squeeze the most out of Apple Pencil, WWDC24](https://developer.apple.com/videos/play/wwdc2024/10214/).
- **S06.** [Apple — What’s new in widgets, WWDC25](https://developer.apple.com/videos/play/wwdc2025/278/).
- **S07.** [Apple — Complications and widgets: Reloaded, WWDC22](https://developer.apple.com/videos/play/wwdc2022/10050/).
- **S08.** [Apple — What’s new in location authorization, WWDC24](https://developer.apple.com/videos/play/wwdc2024/10212/).
- **S09.** [Apple — Discover streamlined location updates, WWDC23](https://developer.apple.com/videos/play/wwdc2023/10180/).
- **S10.** [Apple — Getting the User’s Location, documentación archivada](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/LocationAwarenessPG/CoreLocation/CoreLocation.html).
- **S11.** [ibisPaint — Manual oficial, índice de herramientas](https://ibispaint.com/lecture/index.jsp?lang=en).
- **S12.** [ibisPaint — Details of Brush Parameters](https://ibispaint.com/lecture/index.jsp?no=118).
- **S13.** [ibisPaint — Bucket tool details](https://ibispaint.com/lecture/index.jsp?no=82).
- **S14.** [ibisPaint — Blend mode details](https://ibispaint.com/lecture/index.jsp?no=83).
- **S15.** [Apple — What’s new in the Photos picker, WWDC22](https://developer.apple.com/videos/play/wwdc2022/10023/).
- **S16.** [Apple — Lift subjects from images in your app, WWDC23](https://developer.apple.com/videos/play/wwdc2023/10176/).
- **S17.** [Firebase — Authenticate Using Google Sign-In on Apple Platforms](https://firebase.google.com/docs/auth/ios/google-signin).
- **S18.** [Firebase — Authenticate Using Apple](https://firebase.google.com/docs/auth/ios/apple).
- **S19.** [Firebase — Access data offline](https://firebase.google.com/docs/firestore/manage-data/enable-offline).
- **S20.** [Apple — App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).
- **S21.** [Firebase — Security Rules for Cloud Storage](https://firebase.google.com/docs/storage/security).
- **S22.** [Firebase — App Check with App Attest on Apple platforms](https://firebase.google.com/docs/app-check/ios/app-attest-provider).
- **S23.** [Apple — Xcode SDK and system requirements](https://developer.apple.com/xcode/system-requirements).
- **S24.** [Apple — Developer Program membership details](https://developer.apple.com/programs/whats-included/).
- **S25.** [Tim Oliver — TOCropViewController](https://github.com/TimOliver/TOCropViewController).
- **S26.** [Kean — Nuke](https://github.com/kean/Nuke).
- **S27.** [MetalPetal — repositorio original](https://github.com/MetalPetal/MetalPetal).
- **S28.** [Firebase — Use TypeScript for Cloud Functions](https://firebase.google.com/docs/functions/typescript).
- **S29.** [Apple Developer Forums — Location Push Service Extension Entitlement, 2026](https://developer.apple.com/forums/thread/841098).
- **S30.** [Apple Support — Añadir y editar widgets en el iPhone](https://support.apple.com/es-lamr/118610).
- **S31.** [OpenAI — Custom instructions with AGENTS.md](https://developers.openai.com/codex/guides/agents-md).
- **S32.** [Firebase — Cloud Storage billing requirements](https://firebase.google.com/docs/storage/faqs-storage-changes-announced-sept-2024).

[S02]: https://developer.apple.com/videos/play/wwdc2025/285/
[S03]: https://developer.apple.com/videos/play/wwdc2026/372/
[S04]: https://developer.apple.com/videos/play/wwdc2026/203/
[S05]: https://developer.apple.com/videos/play/wwdc2024/10214/
[S06]: https://developer.apple.com/videos/play/wwdc2025/278/
[S07]: https://developer.apple.com/videos/play/wwdc2022/10050/
[S08]: https://developer.apple.com/videos/play/wwdc2024/10212/
[S09]: https://developer.apple.com/videos/play/wwdc2023/10180/
[S10]: https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/LocationAwarenessPG/CoreLocation/CoreLocation.html
[S11]: https://ibispaint.com/lecture/index.jsp?lang=en
[S12]: https://ibispaint.com/lecture/index.jsp?no=118
[S13]: https://ibispaint.com/lecture/index.jsp?no=82
[S14]: https://ibispaint.com/lecture/index.jsp?no=83
[S15]: https://developer.apple.com/videos/play/wwdc2022/10023/
[S16]: https://developer.apple.com/videos/play/wwdc2023/10176/
[S17]: https://firebase.google.com/docs/auth/ios/google-signin
[S18]: https://firebase.google.com/docs/auth/ios/apple
[S19]: https://firebase.google.com/docs/firestore/manage-data/enable-offline
[S20]: https://developer.apple.com/app-store/review/guidelines/
[S21]: https://firebase.google.com/docs/storage/security
[S22]: https://firebase.google.com/docs/app-check/ios/app-attest-provider
[S23]: https://developer.apple.com/xcode/system-requirements
[S24]: https://developer.apple.com/programs/whats-included/
[S25]: https://github.com/TimOliver/TOCropViewController
[S26]: https://github.com/kean/Nuke
[S27]: https://github.com/MetalPetal/MetalPetal
[S28]: https://firebase.google.com/docs/functions/typescript
[S29]: https://developer.apple.com/forums/thread/841098
[S30]: https://support.apple.com/es-lamr/118610
[S31]: https://developers.openai.com/codex/guides/agents-md
[S32]: https://firebase.google.com/docs/storage/faqs-storage-changes-announced-sept-2024
