# Antojos compartidos

Antojos se abre desde Inicio y reúne deseos de los dos en tarjetas con foto, categoría, título y precio opcional. Las categorías son Viajes, Hogar, Comida, Planes, Regalitos y Otros. La lista permite filtrar y marcar lo que ya hicieron o consiguieron.

## Monedas y detalles

Cada antojo empieza sin moneda. Al ingresar un precio hay que elegirla: MXN, ARS, USD, BRL u otra moneda de la lista. Las tarjetas muestran el código para distinguir monedas que comparten el símbolo `$`. No se convierten importes ni se suman monedas distintas.

- Viajes: destino, fecha, presupuesto y ahorro en la misma moneda. Lo que falta es el presupuesto menos el ahorro, con mínimo cero.
- Regalitos: destinatario, ocasión, fecha y enlace a una publicación o producto.
- Comida: un restaurante con lugar y fecha, o una receta con ingredientes, preparación y enlace.
- Planes: lugar, fecha, costo opcional, enlace y notas.
- Hogar y Otros: foto, precio opcional, enlace y notas.

La fecha es un día de calendario, sin hora ni conversión entre Argentina y México. Los enlaces HTTP/HTTPS se abren mediante `SFSafariViewController`; la API no descarga ni inspecciona las publicaciones enlazadas. No se admiten esquemas de ejecución ni credenciales incrustadas en el enlace.

## Datos compartidos y reintentos

Los dos miembros de la pareja pueden editar. Cada antojo tiene una revisión; si ambos cambian la misma versión, el servidor rechaza la edición atrasada. Los identificadores de solicitud permiten reintentar una respuesta incierta sin crear un duplicado ni aplicar de nuevo un cambio ya confirmado.

Las fotos siguen el almacenamiento privado de la app. Se normalizan, se eliminan metadatos y sólo se descargan con autorización de la pareja y su generación. Las imágenes reemplazadas o eliminadas pasan a limpieza. Cerrar la pareja revoca el acceso y retira las fotos de sus antojos.

Los importes viajan como cadenas decimales canónicas, con hasta diez dígitos enteros y cuatro decimales. No se usan números binarios de punto flotante para calcular lo que falta. La lista admite hasta 200 antojos activos. Los borrados mantienen únicamente un registro mínimo para impedir que un reintento atrasado vuelva a crearlos.

## Contrato

Las operaciones JSON autenticadas son `wishes`, `getWish`, `saveWish`, `deleteWish` y `deleteWishPhoto`. Las fotos usan `PUT /wishPhoto` y `GET /wishPhoto`. Todas requieren `pairId` y `pairEpoch`; las mutaciones incluyen `requestId` y `expectedRevision`. El precio y el código de moneda son ambos nulos o ambos explícitos. No se agrega una moneda por ubicación, idioma o cuenta.

La compilación, pruebas y evidencia de la beta que incorpore Antojos se registran en [CI_GITHUB_ACTIONS.md](CI_GITHUB_ACTIONS.md).
