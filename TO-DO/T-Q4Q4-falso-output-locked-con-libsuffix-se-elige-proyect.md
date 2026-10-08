---
effort: small
id: T-Q4Q4
origin: 'Sesión 2026-10-08: compilando W:\Packages290\Terceros\MakerAI\*.dproj ({$LIBSUFFIX
  AUTO}) tras haber quedado en W:\BPL\290 un MakerAI.bpl sin sufijo de otra compilación'
priority: media
proposal: Probar primero <Proyecto><sufijo><ext> cuando el .dpk declara {$LIBSUFFIX};
  el nombre sin sufijo queda como fallback. Un solo helper usado por GetOutputFromMSBuild
  y por todas las ramas de GetOutputPath (canónica, --test, workspace)
risk: low
type: bug
value: med
verification: 'Repro con paquete LIBSUFFIX y un <Proyecto>.bpl viejo en su carpeta
  de salida: v1.15 => output_locked/exit 1 con el .bpl sufijado recién escrito; corregido
  => pass/exit 0 y output = <Proyecto><sufijo>.bpl. Sin regresión: un bloqueo real
  del .bpl sufijado no da pass'
---
# Falso output_locked con {$LIBSUFFIX}: se elige <Proyecto>.bpl viejo antes que <Proyecto><sufijo>.bpl

## Síntoma

`delphi-compiler.exe W:\Packages290\Terceros\MakerAI\MakerAI.dproj --config=Release` devolvía
`status: output_locked`, exit 1 y `output: W:\BPL\290\MakerAI.bpl`, aunque la compilación había
ido bien: `exit_code` 0, `errors` 0, y `MakerAI290.bpl` y `MakerAI.dcp` reescritos en ese mismo run.
Ningún proceso tenía el `.bpl` cargado. Pasó igual con `MakerAi.RAG.Drivers`, `MakerAi.UI` y `MakerAiDsg`.

## Causa

`Compilar.ProjectInfo.pas`: `GetOutputFromMSBuild` (l. ~169) y `GetOutputPath` (l. ~262) prueban
primero `<Proyecto><ext>` y solo si NO existe prueban `<Proyecto><sufijo><ext>` (`GetLibSuffix`).
Con `{$LIBSUFFIX AUTO}` el compilador escribe `MakerAI290.bpl`, pero había un `MakerAI.bpl` sin
sufijo y viejo en `W:\BPL\290` (de una compilación de los `.dproj` de upstream, que no llevan
sufijo). La herramienta eligió ese, su fecha es anterior a `CompileStartTime` y el paso 7b del
`.dpr` lo marcó `OutputStale` → `output_locked`.

Además, las ramas `--test` y workspace de `GetOutputPath` no prueban el sufijo en ningún caso.
Hoy apenas se notaba en `--test` porque `GetOutputFromMSBuild` (que sí lo prueba) va antes.

La línea de `dcc` no lleva ningún parámetro de sufijo (verificado con `--raw`): el sufijo sale de
la directiva del `.dpk`, así que leerla, como hace `GetLibSuffix`, es la fuente correcta. El
fallo es solo de orden.

## Arreglo

Un helper `FindOutputFile(Dir, Proyecto, Ext, Dproj)`: primero el nombre con sufijo (si el `.dpk`
lo declara), después el nombre sin sufijo. Se usa en `GetOutputFromMSBuild` y en las tres ramas
de `GetOutputPath`.
