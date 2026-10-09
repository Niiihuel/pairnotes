# Validación del corte Railway, notas y avisos

Fecha: 4 de octubre de 2026. Plataforma de trabajo: Linux/NixOS; Xcode y simulador sólo en GitHub Actions.

## Resultados del corte inicial

- CI final: [37227694583](https://github.com/Niiihuel/pairnotes/actions/runs/37227694583), commit `7d53d0258d384fe2ae2c043d90bbecc0cb89089f`, tres jobs aprobados. [Resumen conservado](evidence/railway/ci-summary.json).
- iOS: app, extensión y tests compilaron con Xcode 26.0.1/SDK 26.0; **17 tests nativos aprobados**, cero fallos u omisiones, en iPhone 16e simulado con iOS 26.2/Xcode 26.2. Incluyen editor/persistencia (1), PaperKit (2), configuración/sesión (10) y caché/autorización del widget (4). [Resumen original de xcresult](evidence/railway/native-test-summary.json). Los logs iOS no contienen advertencias ni errores del compilador.
- Selector de simulador: 15 tests Python aprobados en CI.
- Core: 36 XCTest, cero fallos, en contenedor Swift 6.2.4 fijado por digest. Incluye separación de cuentas, persistencia, captura inmutable, reintentos, cancelación selectiva y orden por día/cursor. No verifica frameworks Apple.
- Backend: compilación TypeScript y pruebas con PostgreSQL 17.6, MinIO/S3 y HTTP reales. 52 pruebas/subpruebas aprobadas, cero fallos ni omisiones. Verifican invitaciones, tercero/anónimo, generaciones, imágenes y hashes, idempotencia, sesiones JWT/OIDC y rotación, widget acotado y worker con transporte APNs de prueba. La regresión de limpieza/publicación usa PostgreSQL real y una barrera de almacenamiento controlada.
- Dockerfile Node 22.23.1: build local aprobado.
- Proyecto Xcode: 130 comprobaciones estructurales aprobadas después de regenerar; esto no reemplaza compilación Apple.
- Workflow: `actionlint` y `shellcheck` aprobados.
- Bucket Railway real: PUT privado y HEAD/GET correctos; segundo PUT con `If-None-Match: *` rechazado con 412; contenido original y metadata intactos. Lectura anónima del objeto real rechazada con 403. Ambos objetos ficticios fueron eliminados.

Primera ejecución iOS del nuevo corte: [37225754861](https://github.com/Niiihuel/pairnotes/actions/runs/37225754861), commit `ca3915a`. Linux pasó; el SDK 26.0 rechazó la conformidad incompleta del delegate PaperKit del autosave. El error real mostró tres callbacks obligatorios adicionales, que se implementaron junto con el salto al actor principal. No se presenta esa ejecución como aprobada. Se añadió una prueba nativa que guarda y reabre un borrador mixto mediante el nuevo editor.

La revisión reprodujo y corrigió dos carreras de servidor: publicar durante limpieza/renovación de carga y registrar notificaciones de una sesión antigua después de cambiar de cuenta. Hay regresiones específicas para ambas.

Segunda ejecución iOS: [37226403788](https://github.com/Niiihuel/pairnotes/actions/runs/37226403788), commit `79279b7`, detuvo compilación por el nombre Swift no disponible del código de cancelación Google. Se corrigió usando el valor documentado del header de GoogleSignIn 9.2.0. Esa ejecución tampoco se contabiliza como build aprobada.

Además se separó explícitamente el grupo Keychain privado del compartido, se cercaron callbacks del editor con la cuenta/pareja capturadas, se rechazaron redirects HTTP del widget y se corrigieron carreras de cola y paginación detectadas por revisión.

Tercera ejecución: [37226921423](https://github.com/Niiihuel/pairnotes/actions/runs/37226921423), commit `e2a78bb`. Pasaron Linux y backend; la compilación detectó una combinación inválida de inicializadores `Section` con título y footer. Se corrigieron ambos casos con header explícito. El lockfile de SwiftPM conserva las versiones y revisiones resueltas realmente por Xcode; no se reconstruyó con valores supuestos.

Cuarta ejecución: [37227694583](https://github.com/Niiihuel/pairnotes/actions/runs/37227694583), commit `7d53d02`. Compilación completa de app, extensión y tests aprobada con Xcode 26.0.1/SDK iOS 26.0. Los jobs Linux y backend también aprobaron. La ejecución final aprobó los 17 tests nativos en iOS 26.2. Los tres PNG exportados del roundtrip se inspeccionaron y son idénticos por SHA-256 a los conservados en M0; [procedencia de esta ejecución](evidence/railway/render-provenance.json). Son renders de pruebas, no capturas de un widget instalado. Ambos lockfiles producidos por Xcode coinciden byte a byte con el versionado.

## Comandos ejecutados

Todos los comandos de shell de la sesión usaron el prefijo `rtk`. Comandos principales, además de inspecciones `git`, `rg`, `cat` y consultas a documentación oficial:

```text
rtk docker run --rm ... swift@sha256:eccc7a97f9b9881d9659e2e788081fd7675f86d39793b51200bfb178398b3784 swift test --scratch-path /tmp/pairnotes-build
rtk npm ci
rtk npm run build
rtk npm test                    # con DATABASE_URL/TEST_S3_ENDPOINT locales, ver Backend/README.md
rtk docker build ... Backend
rtk env GEM_HOME=/tmp/pairnotes-gems GEM_PATH=/tmp/pairnotes-gems nix shell nixpkgs#ruby -c ruby scripts/generate_project.rb --replace
rtk env GEM_HOME=/tmp/pairnotes-gems GEM_PATH=/tmp/pairnotes-gems nix shell nixpkgs#ruby -c ruby scripts/ci/validate_project.rb
rtk nix shell nixpkgs#actionlint nixpkgs#shellcheck -c actionlint .github/workflows/ci.yml
rtk git diff --check
rtk railway init --name pairnotes-dev --workspace <workspace-personal> --json
rtk railway environment new development --json
rtk railway environment development
rtk railway bucket create pairnotes-assets --region iad --environment development --json
rtk railway add --database postgres --json
rtk railway add --service pairnotes-api --json
```

Se usó un proceso hijo para leer credenciales S3 sólo en memoria y realizar la prueba sintética con AWS SDK. Las variables API se configuraron con referencias `${{Postgres.DATABASE_URL}}` y `${{pairnotes-assets.<VARIABLE>}}`, sin imprimir secretos. Los tests locales usan credenciales ficticias identificadas como `local-only`; no habilitan un acceso de prueba en la API desplegada.

## Despliegue de desarrollo

Proyecto y bucket constan en [RAILWAY_Y_FLUJO_NOTAS.md](RAILWAY_Y_FLUJO_NOTAS.md). Servicios creados:

- PostgreSQL: `0a37e890-9759-42fa-9cce-322ea1b39960`, nombre `Postgres`.
- API: `53774cc6-9364-4a0c-9e30-7ef697b84de2`, nombre `pairnotes-api`.

Los IDs son metadatos, no credenciales. La API se desplegó desde el commit `e2a78bb` con `railway up Backend --path-as-root --service pairnotes-api --environment development --ci`. Deployment `dd737ba2-1609-4471-a7fd-626b168a10ff`, estado Railway SUCCESS. URL: https://pairnotes-api-development.up.railway.app.

Comprobaciones HTTPS reales: `/healthz` → 200 `{"status":"ok"}`; perfil, imagen privada y widget sin una credencial válida → 401 y `Cache-Control: private, no-store`; un intercambio OAuth de validación sin proveedor configurado → 400 `provider_not_configured`. No se creó una cuenta ficticia en el servicio. [Resultados sanitizados](evidence/railway/http-smoke.json). El bucket rechazó lectura anónima con 403.

Build/deploy/health aprobados no equivalen a login Google/Apple ni entrega APNs configurados. En ese despliegue inicial las audiencias OAuth y la clave APNs seguían pendientes. Se usan referencias privadas del servicio PostgreSQL y del bucket, sin copiar sus secretos al repositorio.

## Configuración de identidad posterior

Actualización de identidad del 4 de octubre de 2026: los IDs reales Google (iOS y Web) y Apple se configuraron en `pairnotes-api/development`. Deployment `275fd8e4-fb03-45ad-bea3-9121ec43ea57`, estado SUCCESS. `/healthz` responde 200 y ambos proveedores rechazan un token deliberadamente inválido con 401 `invalid_identity_token`. [Evidencia](evidence/railway/oauth-config-smoke.json). Se crearon sólo desafíos temporales de validación, sin cuentas ni sesiones. Esto reemplaza el estado anterior de proveedor sin configurar, pero no acredita un login real.

## Configuración APNs posterior

Clave de producción `9K2J26B9QA` cargada en Railway; metadatos y contenido verificados en memoria contra el archivo descargado, sin publicar el secreto. Deployment `be7acb3d-280f-43d5-a17c-888f4170d60f` SUCCESS y `/healthz` 200. Firma ES256 y verificación local aprobadas. [Evidencia sanitizada](evidence/railway/apns-config-smoke.json). No se enviaron notificaciones ni se verificó la autorización APNs de topics con tokens reales, porque todavía no hay instalación firmada. La configuración local usa producción para TestFlight y conserva separados los grupos Keychain.

## Espacio compartido: actualización posterior

El commit `8b08c9b` agrega fotos de perfil, recuerdos, mensajes, fecha de inicio y distancia opcional. Deployment `ef9daeb1-a2d9-4a34-a1cb-3dd41c6e3f64`, entorno `development`, confirmado `SUCCESS`. La comprobación HTTPS posterior obtuvo `/healthz` 200 y rechazo 401 en ocho rutas privadas sin autenticación, siempre con `Cache-Control: private, no-store`. No se leyeron ni modificaron registros de usuarios reales. [Evidencia del despliegue](evidence/railway/couple-space-smoke.json).

La suite backend ampliada pasó **65 pruebas/subpruebas**, con PostgreSQL y S3 locales reales. El despliegue se realizó con `rtk railway up Backend --path-as-root --service pairnotes-api --environment development --ci --message 'PairNotes couple features 8b08c9b: profiles dates messages opt-in distance'`. [Alcance, contratos y validación completa del corte](ESPACIO_COMPARTIDO.md).

## Entrega del 8 de octubre de 2026

Se desplegó `Backend` desde un checkout limpio del commit integrado `a6e7ddb01af9449efd0420ca788e0a139b869f68`. Railway confirmó `SUCCESS` para el deployment `86c838cc-7e96-44b1-b7b4-7b10113993cb` de `pairnotes-api/development`. La beta `1.0 (8.1)`, fuente `0955ded`, incluye la misma URL HTTPS. Entre ambos commits sólo cambió la sincronización de una prueba UI; el árbol `Backend` es idéntico: `ddb5bdeb0c6b4823df7e254704922c93c6acf7cd`.

Las comprobaciones posteriores al despliegue confirmaron `/healthz` 200 y 14 rutas privadas con rechazo 401 `authentication_required` y `Cache-Control: private, no-store`, incluidas fotos compartidas, reacciones y widgets. No se consultaron datos personales ni se modificaron variables, cuentas o sesiones. La procedencia se acredita con el checkout limpio, la subida por CLI y los metadatos del deployment; `/healthz` no publica un SHA y no se inspeccionaron los archivos del contenedor. [Evidencia sanitizada del despliegue](evidence/railway/release-a6e7ddb.json).

La [CI del commit de la beta](https://github.com/Niiihuel/pairnotes/actions/runs/37742965381) aprobó las 82 pruebas/subpruebas de backend con PostgreSQL y S3 controlados. La [lectura posterior de Apple](evidence/testflight/build-8.1.json) confirma disponibilidad interna de `1.0 (8.1)`. Estas comprobaciones no sustituyen los flujos autenticados, la entrega APNs ni la interacción real en dos iPhones.

## Entrega del 9 de octubre de 2026: chat y widgets

Se desplegó `Backend` desde un checkout limpio del commit `1eb56afcf2f76cf7241851b7693d2e182aba1703`, la misma fuente de la beta `1.0 (9.1)`. Railway confirmó `SUCCESS` para el deployment `bc0a95aa-2553-4dd5-ac7e-78cbf4a350f6` de `pairnotes-api/development`. El árbol `Backend` es `d73e03d23711f963daa524f75f1700f85c1d1b3d`. Incluye historial paginado de fotos/cartas, fecha canónica de envío, apertura inmediata al sellar y ubicación automática desde el widget con consentimiento.

La comprobación posterior obtuvo `/healthz` 200 y 17 rutas privadas con rechazo 401 y `Cache-Control: private, no-store`, incluidas `/widgetLocation`, `/photos` y `/letterHistory`. No se consultaron datos personales ni se modificaron cuentas, sesiones o variables. La atribución de fuente procede del checkout limpio y los metadatos de Railway; no se inspeccionó el runtime ni se atribuye un SHA a `/healthz`. [Evidencia sanitizada](evidence/railway/release-1eb56af.json).

La [CI del mismo commit](https://github.com/Niiihuel/pairnotes/actions/runs/37879195944) aprobó 104 pruebas/subpruebas de backend con PostgreSQL y S3 controlados, dentro de 297 comprobaciones aprobadas. Estos resultados no sustituyen los flujos autenticados y la entrega real APNs en dos iPhones.

## Validaciones pendientes

Las suites controladas no validan entrega real APNs, widgets instalados/visibles, permisos interactivos, edición táctil, accesibilidad, rendimiento, restauración de backups ni el comportamiento conjunto en dos iPhones. Linux no tiene acceso a esos dispositivos; CI compila y ejecuta pruebas automáticas. La firma y distribución sí se completaron posteriormente al corte inicial, como registra [CI_GITHUB_ACTIONS.md](CI_GITHUB_ACTIONS.md).

Antes de App Store siguen pendientes eliminación integral de cuenta/datos, política de retención y validación física del producto. Studio/Metal no forma parte de este corte.
