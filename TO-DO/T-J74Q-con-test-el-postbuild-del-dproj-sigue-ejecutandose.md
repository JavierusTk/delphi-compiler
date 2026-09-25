---
effort: trivial
id: T-J74Q
origin: '2026-09-25'
priority: media
proposal: 'tratar --test como el modo workspace: no ejecutar el PostBuild e informarlo
  como post_build_event.skipped + reason'
risk: low
scope: delphi-compiler.dpr paso 7d (PostBuild) en modo --test
type: bug
value: med
verification: 'proyecto de prueba con PostBuild que deja un testigo: con --test =>
  status ok, exit 0, skipped con reason, sin testigo; sin --test => testigo creado'
---
# Con --test el PostBuild del .dproj sigue ejecutándose aunque la salida vaya a la carpeta temporal

## Contexto

Encontrado al cerrar v1.13 (commit `460eb9d`, 2026-09-25). v1.13 dejó de ejecutar el PostBuild en modo
workspace porque la salida se redirige a `ROOT\out` mientras el evento está escrito para el árbol
canónico (rutas `W:\` absolutas, macros `$(...)` que la herramienta no expande).

`--test` tiene exactamente el mismo problema: redirige la salida a `W:\temp\compilar\<PID>`
(`Compilar.Types.TestScratchDir`), pero `delphi-compiler.dpr` paso 7d solo excluye
`Args.WorkspaceRoot <> ''`, así que el PostBuild corre igualmente. Un PostBuild de despliegue
(p. ej. `copy /Y "$(DCC_ExeOutput)\X.exe" "W:\..."`) o falla, y entonces con v1.13 da
`postbuild_error` a una comprobación que no debía tener efectos, o copia un binario que no es
el que la comprobación ha producido.

`--test` es por definición «compilar sin tocar la salida real»; ejecutar el paso de despliegue
contradice ese contrato.

## Propuesta

En el paso 7d, tratar `Args.TestMode` como el modo workspace: no ejecutar e informar
`post_build_event: {command, skipped: true, reason}`.

## Verificación

Con el proyecto de prueba del cierre de v1.13 (PostBuild que escribe un testigo):
`--test` ⇒ status ok, exit 0, `skipped` con `reason`, sin testigo; sin `--test` ⇒ testigo creado.
