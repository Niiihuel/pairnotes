# Validación del corte Railway, notas y avisos

Fecha: 4 de octubre de 2026. Plataforma de trabajo: Linux/NixOS; Xcode y simulador sólo en GitHub Actions.

## Resultados observados

- Core: 36 XCTest, cero fallos, en contenedor Swift 6.2.4 fijado por digest. Incluye separación de cuentas, persistencia, captura inmutable, reintentos, cancelación selectiva y orden por día/cursor. No verifica frameworks Apple.
- Backend: compilación TypeScript y pruebas con PostgreSQL 17.6, MinIO/S3 y HTTP reales. 52 pruebas/subpruebas aprobadas, cero fallos ni omisiones. Verifican invitaciones, tercero/anónimo, generaciones, imágenes y hashes, idempotencia, sesiones JWT/OIDC y rotación, widget acotado y worker con transporte APNs de prueba. La regresión de limpieza/publicación usa PostgreSQL real y una barrera de almacenamiento controlada.
- Dockerfile Node 22.23.1: build local aprobado.
- Proyecto Xcode: 130 comprobaciones estructurales aprobadas después de regenerar; esto no reemplaza compilación Apple.
- Workflow: `actionlint` y `shellcheck` aprobados.
- Bucket Railway real: PUT privado y HEAD/GET correctos; segundo PUT con `If-None-Match: *` rechazado con 412; contenido original y metadata intactos. Lectura anónima del objeto real rechazada con 403. Ambos objetos ficticios fueron eliminados.

Primera ejecución iOS del nuevo corte: [37225754861](https://github.com/Niiihuel/pairnotes/actions/runs/37225754861), commit `ca3915a`. Linux pasó; el SDK 26.0 rechazó la conformidad incompleta del delegate PaperKit del autosave. El error real mostró tres callbacks obligatorios adicionales, que se implementaron junto con el salto al actor principal. No se presenta esa ejecución como aprobada. Se añadió una prueba nativa que guarda y reabre un borrador mixto mediante el nuevo editor.

La revisión reprodujo y corrigió dos carreras de servidor: publicar durante limpieza/renovación de carga y registrar notificaciones de una sesión antigua después de cambiar de cuenta. Hay regresiones específicas para ambas.

Además se separó explícitamente el grupo Keychain privado del compartido, se cercaron callbacks del editor con la cuenta/pareja capturadas, se rechazaron redirects HTTP del widget y se corrigieron carreras de cola y paginación detectadas por revisión.

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

Los IDs son metadatos, no credenciales. El despliegue y las comprobaciones HTTP se anotarán cuando terminen; crear servicios no equivale a tener login/push configurados.

## Pruebas no ejecutadas

Google/Apple con cuentas reales, firma/provisioning, entrega real APNs, widget instalado/visible, edición táctil, accesibilidad, rendimiento, restauración de backups y comportamiento entre dos iPhones. Motivos: faltan los IDs OAuth, valores Apple y clave APNs legítimos; no hay teléfonos conectados ni Mac local. CI permite compilar y ejecutar pruebas automáticas, no simula estas comprobaciones manuales.

No se declara listo para App Store. El siguiente corte propuesto es configuración de identidad/firma y prueba entre dispositivos, junto con eliminación de cuenta/datos y política de retención antes de distribución. No se implementan todavía ubicación/distancia ni Studio.
