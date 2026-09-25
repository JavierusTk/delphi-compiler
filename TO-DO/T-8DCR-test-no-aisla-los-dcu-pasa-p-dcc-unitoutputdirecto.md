---
effort: trivial
id: T-8DCR
origin: '2026-09-25'
priority: media
proposal: sustituir /p:DCC_UnitOutputDirectory por /p:DCC_DcuOutput (y añadir DCC_ObjOutput/DCC_HppOutput
  como hace el modo workspace)
risk: low
scope: Compilar.MSBuild.pas:119-121 (propiedades de salida del modo --test)
type: bug
value: med
verification: 'compilar un paquete con --test: los .dcu aparecen en W:\temp\compilar\<PID>
  y ningún .dcu de W:\DCU\290 cambia de fecha'
---
# --test no aísla los DCU: pasa /p:DCC_UnitOutputDirectory (ignorado) en vez de DCC_DcuOutput y escribe en el DCU canónico

## Contexto

Medido el 2026-09-25 durante la regresión de v1.14. `--test` promete compilar «sin tocar la salida
real» (`Compilar.MSBuild.pas:104-121`), pero pasa a MSBuild:

```
/p:DCC_ExeOutput=<scratch> /p:DCC_UnitOutputDirectory=<scratch> /p:DCC_BplOutput=<scratch> /p:DCC_DcpOutput=<scratch>
```

`DCC_UnitOutputDirectory` no es una propiedad que lean los targets de Delphi: `CodeGear.Delphi.Targets`
usa `DCC_DcuOutput` (líneas 58, 64, 431, 784). Resultado: los DCU van al directorio configurado del
proyecto. Para los proyectos de `Packages290` es el optset compartido
(`Delphi Current Version.optset:9`, `DCC_DcuOutput = $(DCUCMX)$(DELPHIVERSION)` = `W:\DCU\290`), es
decir, **el DCU canónico**.

Evidencia: `delphi-compiler.exe W:\Packages290\VCL\BaseMAX.dproj --test` dejó en `W:\temp\compilar\<PID>`
solo `BaseMAX.dcp`, `.drc`, `BaseMAX290.bpl` y `.map` (ningún `.dcu`), y reescribió 46 `.dcu` de BaseMAX
en `W:\DCU\290` (p. ej. `SchemaModel.dcu`, `Soporte.Incidencia.dcu`, 13:25:20).

El nombre erróneo viene desde v1.0 (`9f88d46`). El modo workspace (`Compilar.MSBuild.pas:139-143`) sí
usa `DCC_DcuOutput`, `DCC_ObjOutput` y `DCC_HppOutput`; solo `--test` está mal.

## Riesgo

Una comprobación con `--test` sobre fuentes modificadas deja DCU de esas fuentes en el árbol canónico,
que luego consumen los demás paquetes y los slots (baseline). Sobre fuentes sin cambios el contenido es
equivalente y solo cambian las fechas.

## Propuesta

Sustituir `/p:DCC_UnitOutputDirectory` por `/p:DCC_DcuOutput`, y redirigir también `DCC_ObjOutput` y
`DCC_HppOutput` como hace el modo workspace.
