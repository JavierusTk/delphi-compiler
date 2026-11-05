---
effort: medium
group: retro-backlog
id: T-HF2B
origin: '2026-09-10'
priority: media
proposal: En modo --workspace leer el .d generado y avisar o fallar si cita un .dcp/.dcu
  canonico de un paquete que el slot tiene en out\. Ademas mover W:\DCP\290 detras
  de $(DCC_UnitSearchPath) en los .dproj de VCL/tests/unit.
scope: W:/Public/delphi-compiler/Compilar.MSBuild.pas:134-148 (leer el .d) y W:/VCL/tests/unit/**/*.dproj
type: bug
value: med
verification: Un .dproj de test con la ruta canonica delante falla o avisa en un slot,
  y con la ruta corregida pasa.
---
# En un slot, una bateria de tests puede enlazar el DCP canonico y dar falso verde sin aviso

Migrado del `RETRO-BACKLOG` (`W:/Agentic-Coding/docs/RETRO-BACKLOG.md`, congelado el 2026-11-05). Filas de origen: RB-WASY (2026-09-10). El texto de cada fila se copia tal cual; la verificación y lo que queda por hacer son del 2026-11-05.

## Fricción (texto original de las filas)

### RB-WASY · 2026-09-10 · dpi-c3-grids (slot s8, piloto B de escalado DPI) — W4

**Fricción.** FALSO VERDE de las baterias DUnitX dentro de un slot cmx-workspace: una bateria de VCL/tests/unit/DBui compilada en el slot enlazaba el DCP CANONICO, no el que el slot acababa de construir. Probado con el fichero de dependencias que emite el compilador (el .d citaba la ruta canonica de dbmax.dcp pese a haberlo compilado en el slot 5 minutos antes; los dos ficheros diferian en fecha y tamano). Consecuencia evitada por poco: en cuanto W4 modifico GridMax.pas, la bateria habria seguido compilando contra el dbmax SIN modificar y habria salido VERDE probando otro codigo. Se detecto por casualidad al medir la linea base, no por ningun gate

**Causa raíz.** El .dproj de la bateria declara <DCC_UnitSearchPath>ruta-canonica-de-fuentes;ruta-canonica-de-DCP;$(DCC_UnitSearchPath)</DCC_UnitSearchPath>, con las rutas canonicas DELANTE. $(DCC_UnitSearchPath) es justo donde el build del slot inyecta out\\DCP\\290 y baseline\\, asi que va ultima y nunca gana. El wrapper del slot hace todo bien (inyecta el search-path correcto); quien lo anula es el .dproj, que es anterior al sistema de slots. Ningun verificador mira contra que DCP se enlazo

**Mitigación propuesta entonces.** (gate) que el compilador en modo --workspace inspeccione el .d que ya genera y FALLE, o al menos avise, si cita un DCP/DCU canonico de un paquete que el slot tiene en out\\: la evidencia ya se produce, solo falta leerla. (doc) mientras tanto, en la guia de slots: antes de fiarse de un verde, grep del .d buscando rutas canonicas .dcp. Corregido en los dos .dproj afectados (commit 6370548), pero el patron esta en TODOS los .dproj de VCL/tests/unit/**

**Estado en el backlog.** PENDIENTE

## Verificación del 2026-11-05: sigue vivo

Comprobación de una sola pasada, de solo lectura, contra el código y el git de ese día. Revalídala antes de arreglar.

- **RB-WASY** (vivo): El compilador solo pasa --depends en modo workspace (Compilar.MSBuild.pas:134,148) y nunca lee el .d; ningun commit lo hace. Los .dproj de W:/VCL/tests/unit siguen con la ruta canonica W:\DCP\290 delante en DCC_UnitSearchPath (17 + 3 ficheros; solo 5 la ponen detras).

## Qué queda por hacer

En modo --workspace leer el .d generado y avisar o fallar si cita un .dcp/.dcu canonico de un paquete que el slot tiene en out\. Ademas mover W:\DCP\290 detras de $(DCC_UnitSearchPath) en los .dproj de VCL/tests/unit.

## Cómo saber que está arreglado

Un .dproj de test con la ruta canonica delante falla o avisa en un slot, y con la ruta corregida pasa.
