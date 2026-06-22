# Bug: "No mapping for the Unicode character exists in the target multi-byte code page"

## Symptom

When compiling certain projects (e.g., `PRESTA.dproj`), the tool returns:

```json
{
  "status": "internal_error",
  "error": "No mapping for the Unicode character exists in the target multi-byte code page"
}
```

The compilation itself succeeds — verified with `--raw` which shows `0 Errores` and a valid `.bpl` output. The error is raised during output processing, not during compilation.

## Root Cause

**`Compilar.MSBuild.pas:159`** — The pipe read loop converts `AnsiString` to `string` (UnicodeString) using the **default system codepage**:

```pascal
Buffer: array[0..4095] of AnsiChar;
...
TotalOutput.Append(string(AnsiString(Buffer)));
```

MSBuild's Spanish-locale output contains characters like:
- `Compilación` (ó = 0xF3 in cp1252)
- `W:\Producción\` (ó in path names)
- `Tiempo transcurrido` (appears to break at this point)

The implicit `AnsiString → string` conversion uses the **current process codepage**. When running under WSL, the process may inherit a Linux locale (UTF-8 / codepage 65001), and the Windows OEM/ANSI codepage used by `cmd.exe` for MSBuild output is typically **cp850** or **cp1252**. The mismatch causes the conversion exception.

The bug is **intermittent** because it depends on the Windows codepage state at process creation time — sometimes the codepage resolves correctly, sometimes it doesn't.

## Evidence

With `--raw`, the output shows the garbled characters and the exception injected mid-string:

```
Compilaci�n iniciada a las...
W:\VCL\Protecci�n
W:\producci�n
...
Tiempo transcur{
  "status": "internal_error",
  "error": "No mapping for the Unicode character exists in the target multi-byte code page"
}rido 00:00:02.20
```

The JSON error blob appears **inside** the word "transcurrido" — the exception is raised during the `Writeln(ErrOutput, MSBuildOutput)` on line 62, which triggers another implicit string conversion. The main `except` handler at line 104-109 catches it and prints the error JSON to stdout, but stderr already has partial output.

## Fix

Replace the implicit codepage-dependent conversion in `RunProcess` with an explicit OEM→Unicode conversion. The MSBuild console output uses the OEM codepage (typically 850 for Spanish Windows):

### Option A: Use `MultiByteToWideChar` with explicit codepage

```pascal
// Replace line 159:
//   TotalOutput.Append(string(AnsiString(Buffer)));
// With:
var
  WideBuffer: string;
  WideLen: Integer;
begin
  WideLen := MultiByteToWideChar(CP_OEMCP, 0, @Buffer[0], BytesRead, nil, 0);
  SetLength(WideBuffer, WideLen);
  MultiByteToWideChar(CP_OEMCP, 0, @Buffer[0], BytesRead, PChar(WideBuffer), WideLen);
  TotalOutput.Append(WideBuffer);
end;
```

### Option B: Force UTF-8 codepage in the subprocess

Prepend `chcp 65001 >nul &&` to the command line in `BuildCommandLine`, and then read the pipe output as UTF-8:

```pascal
// In BuildCommandLine, change:
Result := Format(
  'cmd.exe /c "chcp 65001 >nul & call "%s" && MSBuild.exe ...',
  ...);

// In RunProcess, change line 159:
TotalOutput.Append(TEncoding.UTF8.GetString(TBytes(@Buffer[0]), 0, BytesRead));
```

Option B is cleaner because UTF-8 is lossless and deterministic.

### Also fix the `--raw` output

Line 62 does `Writeln(ErrOutput, MSBuildOutput)` which can also raise the same exception if stdout/stderr have a codepage mismatch. After fixing the pipe reading, this should resolve itself, but consider wrapping it in a try-except as defense.

## Affected Projects

Any project whose MSBuild output contains non-ASCII characters in paths or Spanish messages. For example:
- `PRESTA.dproj` — includes paths like `W:\Producción\`, `W:\VCL\Protección`
- Most CyberMAX projects will be affected since the search paths include these folders

## Reproduction

```bash
# From WSL:
/mnt/w/Agentic-Coding/Tools/delphi-compiler.exe "W:\Packages290\Principales\PRESTA.dproj"
# Returns internal_error (intermittent - may need 1-3 attempts)

# With --raw to see actual compilation succeeded:
/mnt/w/Agentic-Coding/Tools/delphi-compiler.exe "W:\Packages290\Principales\PRESTA.dproj" --raw
# Shows "0 Errores" in stderr, but internal_error JSON in stdout
```

## Files to Modify

- `Compilar.MSBuild.pas` — `RunProcess` method, line 159 (the pipe read conversion)
- Optionally `delphi-compiler.dpr` — line 62 (the `--raw` Writeln to ErrOutput)
