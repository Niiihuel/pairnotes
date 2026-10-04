# PairNotes: backend privado en Railway

Este corte implementa identidad, pareja de dos miembros, envío de notas inmutables,
historial paginado, APNs y acceso limitado del widget. La decisión posterior del
usuario reemplazó Firebase por Railway: este directorio no depende de Auth,
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

Validación ejecutada en Linux: `npm run build`; `npm test` con ambos servicios
locales; `npm audit --omit=dev` (0 vulnerabilidades); `docker build -t
pairnotes-backend:test .`. La suite registró 52 pruebas/subpruebas aprobadas, sin
omisiones. El registro final del proyecto debe reflejar la revisión exacta probada.

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

Las rutas `/auth/*` reciben JSON directo y devuelven JSON directo. Todas las demás
operaciones POST reciben `{data: {...}}` y devuelven `{result: {...}}`. Un fallo usa
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

- `upsertProfile {displayName}` → `{profile:{uid,displayName}}`.
- `getPairState {}` → `{profile,pair:null|{id,members,pairEpoch,status,partner}}`.
- `createInvite {}` → `{token,expiresAt}`; `acceptInvite {token}` → `{pair}`;
  `revokeInvite {}` → `{}`. Invitación opaca de 256 bits, hash únicamente, TTL
  15 minutos; autoaceptación, consumo, revocación y elegibilidad se comprueban en
  la transacción. Aceptar en paralelo no puede agregar un tercer miembro.
- `closePair {pairId,pairEpoch}` → `{}`. Requiere autenticación de menos de cinco
  minutos, incrementa la época, cierra la relación y elimina punteros activos.
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

## Widget y notificaciones

`issueWidgetSession {deviceId}` devuelve `{token,expiresAt}`: siete días, rotación
que invalida el token anterior de ese dispositivo. Autoriza exclusivamente:

- `GET /widgetSnapshot` → `{schemaVersion:1,pairId,pairEpoch,generatedAt,
  validUntil,note:null|{id,revision,revisionHash,publishedAt,authorDisplayName,
  imageSHA256}}`. `validUntil` vence a los 15 minutos o antes si vence el bearer.
- `GET /widgetImage?noteId=<última recibida>` → PNG; 409 si la última nota cambió.
- `POST /widgetPushRegistration {token:<hex>,enabled:<bool>,environment?}`
  registra/desactiva únicamente el token del dispositivo de esa credencial.
  Una retirada antigua no elimina un token más nuevo.

Usan Bearer del widget y verifican dispositivo, vencimiento y época actual.
No autorizan historial, fuente editable ni perfiles privados. Al cerrar pareja,
rotar la credencial o quitar dispositivo fallan inmediatamente nuevas consultas;
la caché del dispositivo puede permanecer hasta su vencimiento y la actualización
que iOS permita ejecutar.

El worker consulta la outbox cada cinco segundos. Un lease transaccional y
confirmaciones por dispositivo/canal permiten varios workers; los fallos se
reintentan con backoff y un canal fallido no impide el otro. APNs estándar usa
`alert` con “Tenés un dibujo nuevo” e identificadores. APNs WidgetKit usa
`widgets`, topic `<bundleID>.push-type.widgets` y `aps.content-changed:true`.
Nunca lleva imágenes, texto de una nota ni fuente. Una caída después de que APNs
acepte y antes del acuse SQL puede duplicar un aviso: no se promete entrega
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

Pendientes de validación con credenciales/dispositivos reales: OAuth Google y
Apple, reautenticación interactiva, APNs de app/widget, permisos, firma y cierre
de sesión en dos iPhones. No se implementaron aún eliminación integral de cuenta,
retención/borrado de dibujos compartidos, fotos de perfil, backups/restauración de
producción, monitoreo/alertas operativas ni ubicación/distancia. El despliegue de
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
