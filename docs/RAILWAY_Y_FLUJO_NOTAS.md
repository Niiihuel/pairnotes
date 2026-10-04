# Railway y envío privado de dibujos

Fecha: 4 de octubre de 2026. Continuación autorizada de M2–M5; no es un cierre de todos los hitos ni una publicación en App Store.

## Decisión que reemplaza el plan

El usuario pidió reemplazar Firebase completo y alojar el backend en Railway. Esta decisión prevalece sobre las secciones Firebase del `Plan_app_pareja_Swift.md`, que se conserva intacto como documento original. La app sigue siendo Swift/SwiftUI, iOS 26 mínimo, con Google y Apple como proveedores de identidad. No se incorpora un servidor Vercel adicional.

Railway ejecuta una API Node 22, PostgreSQL y un bucket S3 privado. La API verifica tokens OIDC de los proveedores y emite sesiones propias. Las apps no reciben credenciales PostgreSQL, S3 ni APNs. El SDK Google Sign-In está restringido al target principal; Core y Widget no dependen de él. Se retiraron los SDKs directos y todos los servicios Firebase. Google Sign-In conserva sus propias dependencias transitivas, sin requerir un proyecto Firebase.

PostgreSQL guarda agregados JSONB identificados por rutas, con clave primaria y transacciones. Un advisory lock serializa las mutaciones para garantizar invitaciones de uso único, pareja de dos miembros y publicación idempotente en esta app privada. Es una decisión de simplicidad para este volumen; escalar a muchas parejas requiere particionar locks, añadir índices específicos y medir consultas. No se presenta como un esquema relacional normalizado ya completado.

Los archivos se sirven mediante endpoints autenticados. No hay enlaces públicos permanentes ni secretos de acceso en los metadatos del historial. La privacidad por autorización no equivale a cifrado de extremo a extremo.

## Comportamiento implementado

- Inicio de sesión con Google/Apple, perfil, invitaciones con vencimiento, revocación y desvinculación con reautenticación reciente. Los identificadores de proveedor se mantienen separados; compartir correo no fusiona cuentas.
- Crear y reabrir varios borradores locales. El editor empieza vacío, usa PaperKit para texto/foto/trazo, permite deshacer/rehacer, guardar, exportar y enviar. Los fixtures ficticios permanecen en tests/mocks, no se muestran como notas reales.
- El autosave espera dos segundos tras cambios; serializa una captura y produce PNG final, widget y miniatura desde esa representación persistida. Una revisión incompatible se conserva en lectura. No se escribió un motor raster/Metal.
- Cada cuenta tiene su propio directorio local. Los borradores de invitado se copian a una cuenta sólo mediante una acción explícita; el original se conserva.
- La cola durable captura fuente y renders inmutables junto con autor, destinatario, pareja y generación. Reintentar conserva el mismo identificador. El estado Enviado sólo aparece después de confirmar la publicación en servidor.
- El servidor valida pertenencia y generación, tamaños, SHA-256 y decodificación/dimensiones PNG. Publica metadatos y el evento de notificación en la misma transacción. Las cargas incompletas no aparecen en el timeline.
- Recuerdos agrupa por día del calendario local y pagina por fecha del servidor más ID. Inicio consulta el último recibido independientemente de las primeras páginas del historial.
- Abrir un aviso o widget resuelve el ID mediante la API autorizada. Sólo la pantalla de detalle marca un dibujo recibido como visto; el widget no lo hace.
- La app consulta cambios mientras está activa, al volver a primer plano, al recuperar conexión y al recibir un aviso. No mantiene un socket permanente en segundo plano.

El catálogo local usa un índice JSON atómico y archivos de revisiones, en lugar de introducir SwiftData en este corte. Comparte modelos y pruebas con Linux. Los archivos de revisiones y la cola todavía requieren una política de limpieza/retención para uso prolongado; no hay presupuesto de memoria/disco medido. PhotosPicker limita el archivo a 20 MB después de cargarlo y reduce los píxeles a 1536; queda pendiente medir el pico de memoria con fotos grandes.

## Avisos y widget

La app solicita permiso de notificaciones sólo al tocar Activar notificaciones. No solicita ubicación. El backend envía alertas directamente a APNs; el texto del aviso es genérico y sólo lleva identificadores para abrir la nota.

El worker usa una cola persistida con leases, reintento y confirmación por dispositivo/canal. Una caída tras la aceptación de APNs y antes del commit puede repetir un aviso; se usa el ID de nota para colapsar alertas. Eso no duplica la publicación. APNs aceptado tampoco acredita que iOS haya mostrado el aviso.

El widget obtiene una credencial propia, revocable y limitada al último dibujo recibido de la pareja/generación actual. Dura hasta siete días y se renueva desde la app; access/refresh tokens de la cuenta permanecen en el Keychain privado. El grupo compartido contiene sólo el acceso acotado del widget. Su caché está ligada al hash de esa credencial y vence según el snapshot del servidor, como máximo quince minutos. Revocación, cambio de pareja o cierre de sesión limpian el acceso local y solicitan recarga.

WidgetKit Push Notifications de iOS 26 usa `WidgetPushHandler` y APNs `apns-push-type: widgets`, topic `<bundle>.push-type.widgets`, payload `aps.content-changed`. El handler registra su token mediante el endpoint acotado; la app también registra el token al conectar. Hay timeline de respaldo y un estado explícito cuando hace falta reconectar. iOS controla presupuesto, ejecución y presentación: no se promete actualización inmediata ni borrado instantáneo de una imagen ya renderizada por el sistema.

## Recursos de desarrollo creados

- Proyecto Railway `pairnotes-dev`: `ae2e0081-67d5-4744-a795-145ea20e6177`.
- Entorno `development`: `a0e005fa-8213-4488-97d6-cab8e99671e0`.
- Bucket `pairnotes-assets`: `689628a5-18a5-440d-8a68-c43c6ff8b636`, región `iad`, direccionamiento virtual-host.
- El entorno `production` que crea Railway por defecto no se usa para el backend de esta entrega.

Se usó la sesión existente de Railway. No se creó una cuenta, no se cambió el plan de facturación y no se usó la cuenta Google laboral encontrada en el entorno. Credenciales del bucket capturadas en memoria del proceso de validación; no se imprimieron ni se guardaron en Git.

Prueba real S3: PUT de bytes ficticios con `If-None-Match: *`; un segundo PUT devolvió 412, GET conservó el original y HEAD preservó su metadata SHA-256. Otra prueba con un objeto existente confirmó 403 para una lectura anónima. Se eliminaron los objetos temporales al terminar. Esta prueba verifica el servicio Railway real; no equivale a probar envío entre iPhones.

## Configuración y aceptación pendientes

La configuración iOS se documenta en [CONFIGURACION_IOS.md](CONFIGURACION_IOS.md). Todavía hacen falta los IDs reales Google/Apple, firma, App Group, grupos Keychain y clave APNs autorizada. La membresía Apple declarada por el usuario no sustituye esas credenciales.

Antes de distribuir: probar login/revocación/reauth en ambos proveedores; dos iPhones y un tercer usuario sin acceso; terminar la app durante upload y reintentar; denegar notificaciones; cambiar cuenta/pareja; instalar widgets pequeño/mediano; token rotation; pantalla bloqueada; app terminada y red intermitente. Registrar tiempo observado del widget, sin convertirlo en garantía. Comprobar VoiceOver, Dynamic Type, importación de fotos, memoria, temperatura y recuperación del editor tras cierre abrupto.

El worker limpia temporales y finales huérfanos con control de generación para no interferir con la publicación. Eliminación de cuenta/datos, retención de dibujos publicados, copias de seguridad/restore, controles operativos de abuso y requisitos de privacidad/App Store necesitan un corte de endurecimiento antes de producción. Distancia/ubicación, widget de bloqueo con avatares y Studio/Metal siguen fuera de esta implementación.

## Fuentes verificadas

- [Railway Storage Buckets](https://docs.railway.com/storage-buckets): almacenamiento S3 privado y limitaciones publicadas.
- [Railway CLI bucket](https://docs.railway.com/cli/bucket): creación, regiones y manejo de credenciales.
- [Railway CLI up](https://docs.railway.com/cli/up): despliegue desde CLI.
- [WidgetKit Push Notifications](https://developer.apple.com/documentation/widgetkit/updating-widgets-with-widgetkit-push-notifications): canal específico para widgets, sujeto a política del sistema.
- [PaperMarkupViewController.Delegate](https://developer.apple.com/documentation/paperkit/papermarkupviewcontroller/delegate-swift.protocol): cambios del documento para autosave.
- Las referencias del editor y las pruebas iniciales permanecen en [REFERENCIAS_M0.md](REFERENCIAS_M0.md).
