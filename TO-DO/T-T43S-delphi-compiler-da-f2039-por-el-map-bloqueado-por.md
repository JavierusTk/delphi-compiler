---
effort: small
group: retro-backlog
id: T-T43S
origin: '2026-09-08'
priority: media
proposal: Reconocer F2039 sobre un .map como bloqueo de salida (output_locked con
  mensaje que diga que hay que cerrar la app) y probar si replace-inuse puede apartar
  tambien el .map; si no, documentarlo en la guia de output_locked.
scope: W:/Public/delphi-compiler/delphi-compiler.dpr (OnlyFileLockErrors / paso 7b)
  y W:/bin/replace-inuse
type: bug
value: med
verification: Compilar con Gestion2000.exe abierto devuelve output_locked citando
  el .map en vez de un error de compilacion.
---
# delphi-compiler da F2039 por el .map bloqueado por la app viva como error de fuente, no bloqueo

Migrado del `RETRO-BACKLOG` (`W:/Agentic-Coding/docs/RETRO-BACKLOG.md`, congelado el 2026-11-05). Filas de origen: RB-HNF8 (2026-09-08). El texto de cada fila se copia tal cual; la verificación y lo que queda por hacer son del 2026-11-05.

## Fricción (texto original de las filas)

### RB-HNF8 · 2026-09-08 · interactiva post-E4 (fix grid inset V, PT-JAVI, misma sesión que /runplan e4-el-shell)

**Fricción.** Con `Gestion2000.exe` abierto por el usuario, `replace-inuse`/rename-en-uso libera `dbmax290.bpl` pero el linker sigue fallando en `dbmax290.map` (F2039): el .map lo tiene abierto SIN share-delete (JclDebug del proceso vivo), no se puede renombrar ni desde cmd, y el build queda a medias (BPL/DCU nuevos, .dcp viejo)

**Causa raíz.** La receta rename-in-use cubre solo el binario mapeado; los ficheros auxiliares del linker (.map) tienen otro modo de apertura y otro dueño (JclDebug), y `delphi-compiler` no permite desactivar el .map por invocación

**Mitigación propuesta entonces.** Que `replace-inuse`/la guía de `output_locked` cubran el .map (probar rename; si no, documentar que hay que cerrar la app) y que `delphi-compiler` detecte F2039 sobre .map y lo reporte como output_locked del .map, no como error de fuente (tool + doc)

**Estado en el backlog.** PENDIENTE

## Verificación del 2026-11-05: sigue vivo

Comprobación de una sola pasada, de solo lectura, contra el código y el git de ese día. Revalídala antes de arreglar.

- **RB-HNF8** (vivo): Grep de 'F2039' y '.map' en delphi-compiler (fuentes, CLAUDE.md, README) y en bin/replace-inuse* no da nada; el compilador solo detecta bloqueos del binario de salida (dpr:186-190, OnlyFileLockErrors). CHANGELOG hasta v1.16 no menciona el .map.

## Qué queda por hacer

Reconocer F2039 sobre un .map como bloqueo de salida (output_locked con mensaje que diga que hay que cerrar la app) y probar si replace-inuse puede apartar tambien el .map; si no, documentarlo en la guia de output_locked.

## Cómo saber que está arreglado

Compilar con Gestion2000.exe abierto devuelve output_locked citando el .map en vez de un error de compilacion.
