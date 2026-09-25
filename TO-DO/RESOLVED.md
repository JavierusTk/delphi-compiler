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
- commit: c699eaa
  note: 'Resuelto en v1.14: con --test el PostBuild se omite y se informa como post_build_event
    {skipped: true, reason: ''test mode: outputs are redirected to a scratch folder
    and the event targets the real output''}. Verificado 2026-09-25 con el proyecto
    de prueba cuyo PostBuild deja un testigo: v1.13 --test => ejecuta el PostBuild
    (testigo creado); v1.14 --test => status ok, exit 0, skipped con reason, sin testigo;
    sin --test => testigo creado.'
  resolved_at: '2026-09-25'
  title: Con --test el PostBuild del .dproj sigue ejecutándose aunque la salida vaya
    a la carpeta temporal
  uid: delphi-compiler:T-J74Q
- commit: c4f3fb4
  note: 'Resuelto en v1.15: --test pasa /p:DCC_DcuOutput (la propiedad que leen los
    targets de Delphi) en vez de DCC_UnitOutputDirectory, y además DCC_ObjOutput/DCC_HppOutput
    como el modo workspace. Verificado 2026-09-25 con foto de fechas y tamaños de
    W:\DCU\290, W:\DCP\290 y W:\BPL\290 (5.109 ficheros) antes y después: BaseMAX.dproj
    --test (v1.15, binario final) => sus 43 .dcu en W:\temp\compilar\<PID> y 0 ficheros
    canónicos cambiados (con v1.14 no dejaba ningún .dcu en el scratch y reescribía
    los de BaseMAX en W:\DCU\290). CyberMAXConsole.dproj --test => ok, 5 .dcu en el
    scratch, 0 cambios en el árbol canónico ni en W:\CyberMAX. Mismos status y contadores
    que v1.14.'
  resolved_at: '2026-09-25'
  title: '--test no aísla los DCU: pasa /p:DCC_UnitOutputDirectory (ignorado) en vez
    de DCC_DcuOutput y escribe en el DCU canónico'
  uid: delphi-compiler:T-8DCR
<!-- agent-todo:resolved:end -->
