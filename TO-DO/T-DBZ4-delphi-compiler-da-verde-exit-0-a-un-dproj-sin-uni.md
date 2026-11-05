---
effort: small
group: retro-backlog
id: T-DBZ4
origin: '2026-08-06'
priority: media
proposal: Contar las units/lineas compiladas que imprime dcc en la salida de MSBuild
  y, si son 0 con MSBuild exit 0, devolver warning o status no-pass con mensaje 'no
  se compilo ninguna unit'.
scope: W:/Public/delphi-compiler/delphi-compiler.dpr (pasos 6-7b) y Compilar.Parser.pas
type: bug
value: med
verification: Compilar un .dproj sin ItemGroup/DelphiCompile devuelve warning o fallo
  en vez de ok, y un proyecto normal sigue dando ok.
---
# delphi-compiler da verde (exit 0) a un .dproj sin units: MSBuild no compila nada y no avisa

Migrado del `RETRO-BACKLOG` (`W:/Agentic-Coding/docs/RETRO-BACKLOG.md`, congelado el 2026-11-05). Filas de origen: RB-051 (2026-08-06). El texto de cada fila se copia tal cual; la verificación y lo que queda por hacer son del 2026-11-05.

## Fricción (texto original de las filas)

### RB-051 · 2026-08-06 · n43-conciliacion

**Fricción.** `Norma43Tests.dproj` sin ItemGroup compilaba "OK" (exit 0, log vacío, 0 artefactos) y una evidencia de REQ-015 se apoyó en ese verde vacuo

**Causa raíz.** MSBuild sin DelphiCompile = no-op silencioso

**Mitigación propuesta entonces.** gate: delphi-compiler delata "0 units compiladas" como error/warning

**Estado en el backlog.** PENDIENTE

## Verificación del 2026-11-05: sigue vivo

Comprobación de una sola pasada, de solo lectura, contra el código y el git de ese día. Revalídala antes de arreglar.

- **RB-051** (vivo): delphi-compiler.dpr:158-200 solo mira errores, fecha del binario (7b) y exit code de MSBuild (7b2); si no hay binario FileAge falla y nada se marca, y no hay ningun conteo de units compiladas. git log desde agosto (v1.12-v1.16) no toca el caso.

## Qué queda por hacer

Contar las units/lineas compiladas que imprime dcc en la salida de MSBuild y, si son 0 con MSBuild exit 0, devolver warning o status no-pass con mensaje 'no se compilo ninguna unit'.

## Cómo saber que está arreglado

Compilar un .dproj sin ItemGroup/DelphiCompile devuelve warning o fallo en vez de ok, y un proyecto normal sigue dando ok.
