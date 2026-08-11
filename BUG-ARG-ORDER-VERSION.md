# BUG — `--version`/`--help` solo se reconocen en primera posición

**Detectado**: 2026-08-11, durante el gesto de aceptación T-46 §4 (sesión de
slot s3), sobre la v1.11 desplegada.

## Síntoma

```
delphi-compiler.exe --version --workspace=C:\cmx-ws\s3    → OK, {"tool":...,"version":"1.11"}, exit 0
delphi-compiler.exe --workspace=C:\cmx-ws\s3 --version    → status "invalid", exit 2
```

Con `--workspace=...` delante, el parser trata el resto posicionalmente y toma
`--version` como fichero de proyecto → `invalid` confuso en vez de la versión.

## Por qué importa (aunque es cosmético)

El guard de slots (`cmx-workspace-guard.py`) sugiere en su mensaje de bloqueo
la plantilla `delphi-compiler.exe --workspace=... <proyecto>`; quien sustituya
`<proyecto>` por `--version` siguiendo la plantilla literalmente se lleva un
`invalid` inexplicable. (El guard ya exceptúa `--version`/`--help` a pelo
desde `Agentic-Coding@030c527`, así que el caso común no pasa por aquí — pero
la combinación sigue siendo legal y engañosa.)

## Fix propuesto (candidato v1.12, no urgente)

Reconocer `--version` (y `--help` si se añade) en **cualquier posición** antes
del parseo posicional de proyecto — o, como mínimo, rechazar argumentos que
empiecen por `--` como nombre de proyecto con un error explícito
("flag desconocido: --version"), que convierte el fallo confuso en uno honesto.

Al resolver: borrar esta ficha y reflejarlo en `CHANGELOG.md`.
