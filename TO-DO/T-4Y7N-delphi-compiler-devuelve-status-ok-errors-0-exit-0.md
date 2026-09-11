---
effort: small
id: T-4Y7N
origin: '2026-09-11'
priority: alta
proposal: status/exit code derivados también del ExitCode de MSBuild; parsear error
  MSB*; test de regresión con TEMP inválido
risk: med
scope: clasificación del ExitCode de MSBuild / tareas no-DCC (BRCC32)
type: bug
value: high
verification: TEMP inválido + dproj con .rc => exit 1 y issue BRCC32; TEMP válido
  => exit 0 y .bpl
---
# delphi-compiler devuelve status ok / errors 0 / exit 0 cuando MSBuild falla en BRCC32 (falso verde sin .bpl)

## Contexto

Medido por el carril BRIDGE (slot s8) el 2026-09-11 (`C:\cmx-ws\s8\dpi-mail\out\049-PROGRESO.md`), compilando `W:\Public\mORMot-MCP-Bridge\src\AutomationTools\AutomationTools.dproj` con `delphi-compiler.exe --workspace=C:\cmx-ws\s8` desde una WSL lanzada por tmux **sin consola de Windows** (sin `%TEMP%` hacia Windows):

```
--- MSBuild Raw Output (ExitCode=1, Len=5706) ---
CodeGear.Common.Targets(1276,5): error MSB4018: The "BRCC32" task failed unexpectedly.
error MSB4018: System.UnauthorizedAccessException: Access to the path is denied.
   at System.IO.Path.InternalGetTempFileName(Boolean checkHost)
```

El JSON salió con `status:"ok"`, `errors:0` y **exit code 0**, y el `.bpl` **no se generó**. El campo interno `exit_code` valía `1`. Con `%TEMP%`/`%TMP%` cruzados al slot, `exit_code` pasa a 0 y compila.

Es decir: un fallo de MSBuild en una tarea que no es DCC (`BRCC32`, `MSB4018`) no se clasifica como error y el contrato de exit code determinista (v1.9: `1` = fallo de build) se rompe. Quien mida builds desde una WSL así lee verdes vacíos.

Dato colateral del mismo bisect: cruzar `%APPDATA%` a esos paquetes provoca `MSB1006 La propiedad no es válida. Modificador: .EXE`; solo `TEMP`/`TMP` compila.

## Propuesta

1. `status` y exit code deben derivar del `ExitCode` de MSBuild además del recuento de errores DCC: `ExitCode<>0` ⇒ `status:"build_failed"` (o `internal_error` si no hay diagnóstico), exit 1, con el primer `error MSB*` en `issues`.
2. Parsear `error MSB\d+` y `task failed unexpectedly` como issues de tipo `msbuild`.
3. Test de regresión: un dproj con un `.rc` y `TEMP` apuntando a una ruta sin permisos ⇒ exit 1.

## Verificación

Reproducir con `TEMP=C:\noexiste\x delphi-compiler.exe <dproj con .rc>` → JSON `status` ≠ ok, exit 1, `issues[0]` cita `BRCC32`/`MSB4018`. Con `TEMP` válido → exit 0 y `.bpl` presente.

## Segunda medición independiente (C2, slot s4, `063-PROGRESO-C2.md` §3)

Mismo falso verde con `MenuControlPackage.dproj`: `"status": "ok"`, `errors: 0`, exit 0, `"exit_code": 1` dentro del JSON y cero artefactos. Además, desde esa WSL **no hay combinación de entorno** con la que `delphi-compiler.exe --workspace` construya `Gestion2000.dproj`: sin `APPDATA` ⇒ `F2613 Unit 'EMemLeaks' not found` (no encuentra `EnvOptions.proj`); con `APPDATA` ⇒ `MSB1006 La propiedad no es válida. Modificador: .EXE`. `cmx-workspace build` vía `wrun` sí compila (exit 0). Dos carriles, dos proyectos, mismo síntoma.
