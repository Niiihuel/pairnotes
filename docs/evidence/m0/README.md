# Evidencia del render nativo

PNG exportados directamente de `Tests.xcresult` en la [ejecución 37222564964](https://github.com/Niiihuel/pairnotes/actions/runs/37222564964), commit `7c60f870cb6542e92611ebd85275801a8e441055`. Test `PaperRoundTripTests/testMixedCompositionSurvivesNativeRoundTrip`, simulador iPhone 16e, iOS 26.2, Xcode 26.2. Los dos tests nativos pasaron. [provenance.json](provenance.json) conserva los nombres originales de los adjuntos.

- [Antes de restaurar](mixed-note-before.png).
- [Primera restauración](mixed-note-restored.png).
- [Segunda restauración](mixed-note-restored-again.png).

Son renders de 384 × 384 de una composición ficticia: texto, ilustración sintética y trazo. Se copiaron sin editar y se inspeccionaron visualmente: los tres elementos están completos y orientados correctamente. El primer roundtrip normaliza el texto desplazándolo un píxel en Y; sus píxeles coinciden tras esa traslación uniforme. Imagen y trazo no cambian. La segunda restauración tiene igualdad exacta del raster completo con la primera. El test también verifica el contenido textual indexable y rechaza fuentes corruptas.

Estos PNG no son capturas de una sesión de edición ni de un widget visible. No acreditan interacción, importación de fotos reales, firma, App Groups o comportamiento en un iPhone físico. El `.xcresult` completo, fuente nativa y build de simulador están en los artefactos temporales de ese run.
