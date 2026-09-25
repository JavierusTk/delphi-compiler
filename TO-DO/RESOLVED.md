# RESOLVED

Tombstones for resolved TO-DO items (machine-readable; read by `agent-todo lint`).

<!-- agent-todo:resolved:start -->
- commit: c699eaa
  note: 'Resuelto en v1.14. Los errores de MSBuild (MSBnnnn, con origen o ''MSBUILD
    :'') se parsean como issues de error, con su excepción y pila como context; un
    exit de MSBuild distinto de 0 sin línea de error reconocida da status error +
    issue MSBUILD_EXIT. Verificado 2026-09-25 contra v1.13 con un .dproj con .rc:
    con TEMP=C:\noexiste\x, v1.13 => status ok, exit 0, sin binario y PostBuild ejecutado;
    v1.14 => status error, exit 1, issue MSB4018 ''The "BRCC32" task failed unexpectedly.''
    con context ''System.IO.IOException: El nombre del directorio no es válido.'';
    con TEMP válido => ok, exit 0 y exe. Fallo sin código MSB (<Error> propio) =>
    MSBUILD_EXIT, exit 1. output_locked conservado (rebuild con exe bloqueado => output_locked
    con MSB3061). Regresión: CyberMAXConsole y BaseMAX con --test, mismos contadores
    en v1.13 y v1.14. La forma ''MSBUILD : error MSB1006'' del segundo caso se comprobó
    contra el patrón, no reproducida en vivo.'
  resolved_at: '2026-09-25'
  title: delphi-compiler devuelve status ok / errors 0 / exit 0 cuando MSBuild falla
    en BRCC32 (falso verde sin .bpl)
  uid: delphi-compiler:T-4Y7N
<!-- agent-todo:resolved:end -->
