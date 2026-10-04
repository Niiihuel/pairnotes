# PairNotes: backend privado en Railway

Este corte implementa identidad, pareja de dos miembros, envío de notas inmutables,
historial paginado, perfiles con avatar, fecha de la relación, recuerdos, mensajes,
distancia con consentimiento, APNs y acceso limitado de los widgets. La decisión
posterior del usuario reemplazó Firebase por Railway: este directorio no depende de Auth,
Firestore, Storage, Functions ni FCM. Los servicios son Node 22, PostgreSQL y un
bucket S3 privado de Railway. No contiene credenciales reales.

## Arranque y pruebas locales

Requisitos: Node 22, npm y Docker con Compose. Ejecutar desde `Backend`:

```sh
npm ci
docker compose -f compose.test.yml up -d
export DATABASE_URL=postgresql://pairnotes:pairnotes-local-only@127.0.0.1:55432/pairnotes_test
export TEST_S3_ENDPOINT=http://127.0.0.1:59000
node scripts/wait-for-test-services.cjs
npm test
docker compose -f compose.test.yml down
```

Las contraseñas de Compose son fixtures ficticias, los puertos se publican sólo en
loopback y los tests rechazan conexiones remotas. MinIO se usa únicamente para
pruebas S3 locales; Railway almacena los archivos reales. Las imágenes de prueba
están fijadas por digest. Los tests de negocio levantan un servidor HTTP real,
PostgreSQL y S3; sólo sustituyen el proveedor externo de identidad y el transporte
APNs. Los tests de autenticación usan firmas RSA/JOSE reales y PostgreSQL. No
afirman haber iniciado sesión con Google/Apple ni enviado una push real.

En el corte `8b08c9b`, CI confirmó `npm test` —que incluye `npm run build`— con
65 pruebas/subpruebas aprobadas. Cubren también aislamiento de pareja en mensajes,
avatares y recuerdos, normalización de fotos, permisos del widget, fechas,
consentimiento, rechazo de muestras antiguas y revocación de ubicación. La
validación anterior en Linux incluyó `npm audit --omit=dev` (0 vulnerabilidades)
y `docker build -t pairnotes-backend:test .`; esos resultados no sustituyen una
nueva auditoría o build de contenedor del corte actual.

## Configuración de Railway

El servicio se construye con `Backend` como raíz y `railway.json`. `Dockerfile`
usa Node 22.23.1, instala mediante lockfile, compila TypeScript, elimina dependencias
de desarrollo y ejecuta como usuario `node`. Arranca con `node lib/server.js`.
El puerto es `PORT`, o 8081 localmente; `/healthz` comprueba disponibilidad del
worker/SQL. Un healthcheck aprobado no equivale a OAuth o APNs configurados.

Variables privadas/referencias del servicio:

- `DATABASE_URL`: referencia privada del servicio PostgreSQL.
- `BUCKET`, `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`, `REGION`, `ENDPOINT`: referencias
  al bucket Railway. El endpoint utiliza virtual-host addressing; no activar
  `S3_FORCE_PATH_STYLE` en Railway. En MinIO local sí se usa path style.
- `GOOGLE_CLIENT_IDS`, `APPLE_CLIENT_IDS`: listas separadas por coma de audiences
  reales permitidas. Un proveedor sin IDs configurados rechaza el login con
  `provider_not_configured`.
- `PAIRNOTES_APNS_KEY`: contenido P8; `PAIRNOTES_APNS_KEY_ID`,
  `PAIRNOTES_APNS_TEAM_ID`, `PAIRNOTES_APP_BUNDLE_ID`: configuración Apple real.
  Guardarlas como secretos del servicio; jamás en repositorio ni argumentos de
  comandos que se impriman. Sin ellas los eventos conservan su estado pendiente.

El entorno APNs se registra por dispositivo: `development` para firma de
desarrollo, `production` para distribución. La app y la extensión tienen tokens
distintos. Antes de publicar deben configurarse los identificadores definitivos,
capacidades de Apple, grupos compartidos/Keychain, OAuth y claves APNs. Un miembro
del equipo con acceso autorizado puede enlazar la CLI desde `Backend` y ejecutar
`railway up --service <servicio> --environment development` después de revisar el
servicio y sus variables; este comando no forma parte de los tests.

La prueba de compatibilidad realizada por el agente principal en el bucket de
desarrollo de Railway comprobó `If-None-Match: *`: primer PUT exitoso, segundo PUT
412, GET y metadata SHA256 conservados; el objeto ficticio se eliminó después.
La prueba no involucró dibujos privados ni verificó APNs/OAuth.

## Identidad HTTP

Las rutas `/auth/*` y `/widgetPushRegistration` reciben JSON directo y devuelven
JSON directo. Las operaciones POST del producto reciben `{data: {...}}` y
devuelven `{result: {...}}`. Los PUT de imágenes reciben bytes y devuelven JSON
directo. Un fallo de una operación POST del producto usa
`{error:{status,message,details:{reason}}}`; imágenes/widgets usan `{reason}` con
status HTTP adecuado. Las razones son estables para el cliente, nunca incluyen
tokens, fuente editable o texto íntimo. Todas las respuestas llevan
`Cache-Control: private, no-store`.

- `POST /auth/challenge {provider:"apple"|"google"}` devuelve
  `{challengeId,nonce,expiresAt}`. El cliente envía **SHA256 hex del nonce** al
  proveedor OAuth. El servidor guarda sólo su hash, vence a los cinco minutos y
  consume el desafío una sola vez.
- `POST /auth/exchange {provider,idToken,challengeId,deviceId?}` devuelve
  `{accessToken,refreshToken,expiresAt,identity:{uid,displayName},provider}`.
  `Authorization: Bearer <accessToken actual>` convierte esta operación en
  reautenticación: exige la misma identidad y autenticación reciente.
- `POST /auth/refresh {refreshToken}` rota ambos secretos y devuelve la misma
  estructura. El acceso vence en 15 minutos; la familia de refresh tiene una
  vida absoluta de 30 días. Reutilizar un refresh consumido revoca la familia y
  el registro del dispositivo asociado.
- `GET /auth/session` devuelve `{identity,provider,expiresAt}`.
- `POST /auth/signout {deviceId?}` revoca la familia y el dispositivo, invalidando
  sus sesiones de widget. Estas dos rutas requieren Bearer de acceso.

JOSE verifica firma RS256, issuer fijo Google/Apple, audience permitida, `exp`,
`iat`, nonce y `azp` cuando corresponda. Se conserva `auth_time`; en su ausencia
se usa el `iat` validado. No se fusionan cuentas por email/nombre. Cada identidad
`provider+sub` recibe un UID UUID. Bearers de acceso, refresh y widget son 32 bytes
aleatorios; PostgreSQL conserva hashes. Hay límite de 60 solicitudes/minuto por
peer HTTP, ocho autenticaciones concurrentes por instancia y memoria limitada.
No se confía en `X-Forwarded-For`; con un proxy el límite se comparte. Un producto
mayor necesita política WAF y límite distribuido adecuados.

## Contratos del producto

Todas las operaciones siguientes requieren Bearer de acceso, derivan el UID de
la sesión y rechazan IDs/épocas ajenos. Los tiempos de las respuestas son ms Unix.

- `upsertProfile {displayName}` → `{profile:{uid,displayName,avatar}}`.
  Cambiar el nombre conserva el avatar. `avatar` es `null` o `{id,sha256}`.
- `getPairState {}` → `{profile,pair:null|{id,members,pairEpoch,status,startedOn,partner}}`.
  `partner` tiene la misma forma pública del perfil.
- `createInvite {}` → `{token,expiresAt}`; `acceptInvite {token}` → `{pair}`;
  `revokeInvite {}` → `{}`. Invitación opaca de 256 bits, hash únicamente, TTL
  15 minutos; autoaceptación, consumo, revocación y elegibilidad se comprueban en
  la transacción. Aceptar en paralelo no puede agregar un tercer miembro.
- `closePair {pairId,pairEpoch}` → `{}`. Requiere autenticación de menos de cinco
  minutos, incrementa la época, cierra la relación y elimina punteros activos,
  consentimientos, coordenadas y distancia. Las consultas posteriores a los
  contenidos de esa pareja quedan denegadas; no implica borrado integral del historial.
- `createUploadSession {pairId,pairEpoch,idempotencyKey,noteId,revision,
  revisionHash,assets:[{role,sha256,byteCount,contentType}]}` →
  `{sessionId,noteId,paths:{source,final,widget,thumbnail},published}`.
  Son exactamente cuatro activos. `revisionHash` coincide con el hash fuente.
  El mismo key/manifest devuelve la misma sesión; reutilizarlo con otros bytes
  falla. Una sesión expirada se renueva mediante esta operación explícita sólo
  con la misma firma y pertenencia actual. La fuente es `application/octet-stream`
  (máximo 20 MiB); derivados PNG cuadrados: final hasta 2048 px/12 MiB, widget
  hasta 1024 px/4 MiB y miniatura hasta 480 px/4 MiB.
- `PUT /upload?sessionId=<id>&role=<role>` lleva los bytes, Bearer de acceso,
  Content-Type y `X-Content-SHA256`. Sólo el dueño carga activos del manifiesto;
  PUT repetido de los mismos bytes es idempotente. No se exponen URLs de escritura
  ni credenciales S3 al cliente.
- `finalizeNote {sessionId,pairId,pairEpoch}` → `{note}`. Verifica existencia,
  tamaño, tipo, SHA256 y decodifica los PNG. Congela activos mediante PUT
  condicional, después confirma nota, puntero del receptor y evento de push en
  una sola transacción SQL. Finalizaciones simultáneas/repetidas devuelven una
  única nota. Nunca se confirma el envío por terminar sólo la carga.
- `timeline {pairId,pairEpoch,limit?,cursor?:{publishedAt,noteId}}` →
  `{notes,nextCursor}`. Máximo 50, orden descendente por publicación e ID.
  `latestReceivedNote {pairId,pairEpoch}` → `{note:null|note}`; `note
  {pairId,pairEpoch,noteId}` → `{note}`. El agrupamiento por días es del cliente,
  con su calendario/zona horaria. Borradores no aparecen en estas rutas.
- `GET /image?path=<ruta>` verifica la relación activa y la ruta exacta declarada
  por una nota publicada. Fuente, render y miniatura se descargan autenticados,
  sin URLs públicas permanentes.
- `markNoteViewed {pairId,pairEpoch,noteId}` sólo acepta al receptor. Un fetch del
  widget no marca una nota como vista.
- `registerDevice {deviceId,apnsToken?,apnsEnvironment?,widgetPushToken?,
  widgetPushEnvironment?}`; `unregisterDevice {deviceId}`. Máximo 10 dispositivos.
  `apnsToken:null` desactiva sólo el aviso de la app, preservando el widget.
  La instalación y cada token/canal/entorno tienen un único dueño: cambiar de
  cuenta transfiere el registro y revoca el widget anterior incluso si el logout
  anterior no llegó al servidor. El registro también verifica la sesión vinculada
  a esa instalación para rechazar una solicitud antigua que llegó tarde.
  Los entornos válidos son `development` y `production`; sin entorno configurado
  el worker mantiene pendiente ese canal.

La nota publicada tiene `id,pairId,pairEpoch,authorId,recipientId,revision,
revisionHash,publishedAt,paths,widgetSHA256`. Rutas finales:
`pairs/{pairId}/{pairEpoch}/{noteId}/{role}`; temporales:
`tmp/{uid}/{sessionId}/{role}`. Nunca se guarda binario/Base64 en PostgreSQL.

## Espacio compartido, fotos y mensajes

Estas operaciones usan los mismos Bearers de acceso y sobres POST del producto.
`pairId` y `pairEpoch` identifican siempre una pareja activa a la que pertenece
la sesión. Los IDs de recuerdos y mensajes admiten de 1 a 128 caracteres ASCII
`A-Z`, `a-z`, `0-9`, `_` y `-`. Los límites de texto se cuentan en unidades UTF-16.

- `getCoupleSpace {pairId,pairEpoch}` → `{profiles,startedOn,latestMessage,
  memories,location}`. Devuelve los dos perfiles públicos, hasta 200 recuerdos
  ordenados por `date` y el último mensaje **recibido** por la sesión, o `null`.
- `updatePairDetails {pairId,pairEpoch,startedOn,timeZone?}` → `{pair}`.
  `startedOn` es una fecha de calendario `YYYY-MM-DD` válida o `null`; no contiene
  hora. Rechaza fechas futuras usando la zona IANA indicada, o UTC si se omite.
- `upsertMemory {pairId,pairEpoch,memoryId,title,date,kind,recursYearly?,body?,
  noteId?}` → `{memory}`. `kind` es `date` o `memory`; título obligatorio hasta
  120 unidades, cuerpo hasta 2000, fecha `YYYY-MM-DD`. Admite hasta 200 elementos
  por pareja. Ambos miembros pueden editarlos; conserva autor y fecha de creación.
  `noteId` debe pertenecer a la misma pareja; `null` quita el vínculo. Una foto y
  una nota vinculada pueden coexistir. Los campos opcionales omitidos conservan
  su valor anterior; una foto se modifica mediante su ruta específica.
- `memories {pairId,pairEpoch}` → `{memories}`; `deleteMemory
  {pairId,pairEpoch,memoryId}` → `{}`. El borrado retira también su foto para limpieza.
- `PUT /profileAvatar` recibe PNG/JPEG del perfil de la sesión y devuelve
  `{profile}`. `GET /profileAvatar?uid=<uid>&avatarId=<id>` devuelve PNG sólo del
  propio usuario o de su pareja activa. `avatarId` es opcional; al enviarlo, un
  cambio de foto produce 409. `deleteProfileAvatar {}` → `{profile}` retira la foto.
- `PUT /memoryPhoto?pairId=<id>&pairEpoch=<epoch>&memoryId=<id>` recibe PNG/JPEG y
  devuelve `{memory}`. `GET` en esa misma ruta descarga PNG; `photoId=<id>` es
  opcional y detecta una foto sustituida con 409. `deleteMemoryPhoto
  {pairId,pairEpoch,memoryId}` → `{memory}` elimina sólo la foto del recuerdo.
- `sendMessage {pairId,pairEpoch,messageId,text}` → `{message}`. Texto obligatorio
  hasta 500 unidades; receptor derivado de la pareja, nunca elegido por el cliente.
  Repetir el ID con el mismo autor y texto es idempotente; otro contenido falla.
  Confirma mensaje, puntero del receptor y evento APNs en una transacción.
- `messages {pairId,pairEpoch,limit?,cursor?:{sentAt,messageId}}` →
  `{messages,nextCursor}`. Página predeterminada de 30, máximo 50, orden descendente
  por envío e ID. No admite acceso desde una credencial del widget.

Un recuerdo contiene `id,pairId,pairEpoch,authorId,title,date,kind,recursYearly,
body,noteId,photo,createdAt,updatedAt`; `photo` es `null` o `{id,sha256}`. Un mensaje
contiene `id,pairId,pairEpoch,authorId,recipientId,text,sentAt`. Los tiempos son ms Unix.

Las fotos entrantes se limitan a 5 MiB y 4096² píxeles, se decodifican y normalizan
en el servidor, corrigiendo orientación y eliminando metadatos EXIF/GPS. El PNG de
avatar mide como máximo 256 × 256 px y 512 KiB; el de un recuerdo, 1536 × 1536 px
y 5 MiB. Los bytes viven en S3 privado; las respuestas sólo exponen ID y SHA256,
sin claves del bucket. Las descargas vuelven a comprobar permisos y la foto actual
después de leer S3. Cambiar/borrar fotos las vuelve inaccesibles antes de su limpieza física.

## Ubicación y distancia con consentimiento

- `setLocationConsent {pairId,pairEpoch,enabled,deviceId?}` → `{location}`.
  Activar requiere un dispositivo registrado y vinculado a la sesión actual;
  sólo ese dispositivo puede aportar muestras. Repetir el mismo estado es
  idempotente. Cambiar de fuente incrementa `consentVersion` y elimina la muestra
  propia y la distancia calculada.
- `updateLocation {pairId,pairEpoch,deviceId,consentVersion,sequence,latitude,
  longitude,horizontalAccuracy,capturedAt}` → `{location}`. Requiere consentimiento
  activo de esa versión y dispositivo; secuencia y fecha deben avanzar. Rechaza
  coordenadas fuera de rango, precisión fuera de 0–5000 m, muestras de 30 minutos
  o más de antigüedad, o más de un minuto en el futuro. `capturedAt` se expresa en ms Unix.

`location` contiene `{sharingEnabled,sourceDeviceId,consentVersion,distance}`.
`distance` contiene siempre `{status,meters,updatedAt,accuracyMeters}`: `disabled`
si falta algún consentimiento, `waiting` hasta disponer de dos muestras,
`available` hasta 15 minutos desde la muestra más antigua y `stale` después.
Al cumplir 30 minutos, `meters` y `accuracyMeters` pasan a `null`; se conserva la
fecha de referencia para indicar antigüedad. La distancia se redondea a 100 m y
la incertidumbre combina ambas precisiones, redondeadas hacia arriba; un valor
redondeado a cero no prueba que ambos estén juntos.

No existe un endpoint de lectura de coordenadas. Se conserva sólo la última
muestra privada por usuario, con vencimiento a los 30 minutos y limpieza periódica.
Pausar elimina ambas muestras y la distancia, manteniendo independiente el
consentimiento de la otra persona. Cerrar sesión, retirar/transferir el dispositivo
fuente o cerrar la pareja revoca el acceso correspondiente y elimina las muestras.
El servidor no activa permisos del teléfono ni garantiza GPS permanente o muestras
en segundo plano; esas decisiones y restricciones corresponden a la app y a iOS.

## Widget y notificaciones

`issueWidgetSession {deviceId}` devuelve `{token,expiresAt}`: siete días, rotación
que invalida el token anterior de ese dispositivo. Autoriza exclusivamente:

- `GET /widgetSnapshot` → `{schemaVersion:1,pairId,pairEpoch,generatedAt,
  validUntil,note:null|{id,revision,revisionHash,publishedAt,authorDisplayName,
  imageSHA256},profiles,startedOn,latestMessage,distance}`. Los campos adicionales
  conservan `schemaVersion:1`; usan las formas públicas descritas arriba. El mensaje
  es sólo el último recibido y la distancia nunca incluye coordenadas.
  `validUntil` vence en un máximo de 15 minutos, antes si vence el bearer o si la
  distancia mostrable alcanza los 30 minutos de antigüedad.
- `GET /widgetImage?noteId=<última recibida>` → PNG; 409 si la última nota cambió.
- `GET /widgetAvatar?uid=<miembro>&avatarId=<id>` → PNG actual de uno de los dos
  miembros. `avatarId` es opcional y permite rechazar una foto sustituida con 409.
- `POST /widgetPushRegistration {token:<hex>,enabled:<bool>,environment?}`
  registra/desactiva únicamente el token del dispositivo de esa credencial.
  Una retirada antigua no elimina un token más nuevo.

Usan Bearer del widget y verifican dispositivo, vencimiento y época actual.
Autorizan sólo ese resumen, la imagen de la última nota, los avatares de los dos
miembros y el registro push propio. No autorizan historial de notas o mensajes,
recuerdos/fotos de recuerdos, fuentes editables, coordenadas ni modificaciones de
la pareja. Un Bearer del widget tampoco autentica las rutas de la app. Al cerrar pareja,
rotar la credencial o quitar dispositivo fallan inmediatamente nuevas consultas;
la caché del dispositivo puede permanecer hasta su vencimiento y la actualización
que iOS permita ejecutar.

El worker consulta la outbox cada cinco segundos. Un lease transaccional y
confirmaciones por dispositivo/canal permiten varios workers; los fallos se
reintentan con backoff y un canal fallido no impide el otro. APNs estándar usa
`alert` con “Tenés un dibujo nuevo” o “Tenés un mensaje nuevo” e identificadores.
APNs WidgetKit usa `widgets`, topic `<bundleID>.push-type.widgets` y
`aps.content-changed:true`. Nunca lleva imágenes, contenido del mensaje, texto de
una nota ni fuente. Una caída después de que APNs acepte y antes del acuse SQL
puede duplicar un aviso: no se promete entrega
exactamente una vez. iOS decide cuándo mostrar la actualización del widget.

## Persistencia, mantenimiento y límites pendientes

`database.ts` utiliza agregados JSONB en `documents(path PRIMARY KEY,value)`.
La clave única y un advisory lock transaccional serializan las mutaciones,
incluyendo relación, idempotencia, refresh y leases. Esto es una decisión explícita
para una app privada pequeña; se debe particionar locks/índices antes de escalar.
No existe un endpoint genérico que permita leer/escribir esos documentos.

El worker elimina temporales vencidos y finales huérfanos tras una hora de gracia,
preservando activos publicados. Serializa eliminación con renovación de upload;
la interrupción deja la limpieza reintentable. Cada GC/renovación aumenta la
generación interna de la sesión; una finalización antigua no puede confirmar una
nota después de que cambió esa generación, aunque su upload S3 haya quedado
demorado. Una prueba reproduce esa intercalación con PostgreSQL y una barrera.
También purga credenciales,
desafíos y límites vencidos; los refresh usados sobreviven hasta el vencimiento
absoluto de su familia para detectar reutilización.

El mantenimiento también elimina coordenadas vencidas. Las fotos privadas
obsoletas o cargas sin adjuntar se eliminan con una hora de gracia desde su
vencimiento. Relee el estado antes de borrar y conserva las imágenes adjuntas;
un fallo de S3 deja la eliminación
pendiente para otro ciclo. Las fotos retiradas no siguen autorizadas durante esa gracia.

Pendientes de validación con credenciales/dispositivos reales: OAuth Google y
Apple, reautenticación interactiva, APNs de app/widget, permisos, firma y cierre
de sesión en dos iPhones; también avatares, fotos de recuerdos, mensajes, permisos
de ubicación, pausa/cambio de dispositivo y widgets con datos antiguos en hardware
real. No se implementaron aún eliminación integral de cuenta, retención/borrado
de dibujos compartidos, backups/restauración de producción ni monitoreo/alertas
operativas. Los recordatorios locales y la exportación a Calendario pertenecen a
la app; este servidor no programa esas alertas ni accede al calendario. El despliegue de
desarrollo y sus recursos deben registrarse por separado; ningún test local los
declara listos para App Store.

## Documentación oficial consultada

- [Google: verificar identidad en backend](https://developers.google.com/identity/sign-in/ios/backend-auth),
  [OpenID Connect](https://developers.google.com/identity/openid-connect/openid-connect).
- [Apple: verificar un usuario](https://developer.apple.com/documentation/signinwithapple/verifying-a-user).
- [Apple: WidgetKit push](https://developer.apple.com/documentation/widgetkit/updating-widgets-with-widgetkit-push-notifications),
  [APNs requests](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns).
- [PostgreSQL advisory locks](https://www.postgresql.org/docs/current/explicit-locking.html#ADVISORY-LOCKS).
- [Railway storage buckets](https://docs.railway.com/storage-buckets),
  [Dockerfiles](https://docs.railway.com/builds/dockerfiles),
  [healthchecks](https://docs.railway.com/deployments/healthchecks).
- [AWS SDK: PutObject](https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/s3/command/PutObjectCommand/).
