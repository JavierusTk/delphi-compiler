# delphi-compiler

A command-line wrapper around MSBuild for Delphi projects that produces structured JSON output. Designed for integration with AI coding assistants and automated build pipelines.

## What it does

1. Invokes MSBuild via RAD Studio's `rsvars.bat` to compile a `.dproj` project
2. Parses the compiler output (errors, warnings, hints)
3. Enriches each issue with source code context around the error line
4. Optionally looks up undeclared identifiers and missing files
5. Outputs everything as a single JSON object to stdout

## Usage

```
delphi-compiler.exe <project.dproj> [options]
```

The project path can be either Windows (`W:\path\project.dproj`) or Linux/WSL (`/mnt/w/path/project.dproj`) format.

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--config=Debug\|Release` | `Debug` | Build configuration |
| `--platform=Win32\|Win64` | `Win32` | Target platform |
| `--test` | off | Compile to a temp folder (don't overwrite existing output) |
| `--max-errors=N` | `3` | Max errors to include in output (1-10) |
| `--context-lines=N` | `5` | Lines of source context around each error (0-20) |
| `--raw` | off | Echo raw MSBuild output to stderr |
| `--wsl` | off | Output file paths in Linux format (`/mnt/x/...`) |

### Example

```bash
delphi-compiler.exe W:\MyProject\MyProject.dproj --config=Release --max-errors=5
```

## JSON Output

### Successful compilation

```json
{
  "status": "ok",
  "project": "MyProject.dproj",
  "project_path": "W:\\MyProject\\MyProject.dproj",
  "config": "Release",
  "platform": "Win32",
  "output": "W:\\MyProject\\Win32\\Release\\MyProject.exe",
  "time_ms": 2340,
  "exit_code": 0,
  "errors": 0,
  "warnings": 0,
  "hints": 0,
  "issues": []
}
```

### Compilation with errors

```json
{
  "status": "error",
  "project": "MyProject.dproj",
  "project_path": "W:\\MyProject\\MyProject.dproj",
  "config": "Debug",
  "platform": "Win32",
  "time_ms": 1580,
  "exit_code": 1,
  "errors": 1,
  "warnings": 0,
  "hints": 0,
  "issues": [
    {
      "type": "error",
      "code": "E2003",
      "file": "W:\\MyProject\\MainForm.pas",
      "line": 42,
      "column": 5,
      "message": "Undeclared identifier: 'DoSomething'",
      "context": [
        "  40:   begin",
        "  41:     Result := 0;",
        "  42: >>> DoSomething(Value);",
        "  43:     Exit;",
        "  44:   end;"
      ],
      "lookup": {
        "found": true,
        "symbol": "DoSomething",
        "results": [
          {
            "unit": "HelperUtils",
            "path": "HelperUtils.pas",
            "type": "procedure",
            "line": 15
          }
        ]
      }
    }
  ]
}
```

### Status values

| Status | Meaning |
|--------|---------|
| `ok` | Compiled successfully, no issues |
| `hints` | Compiled successfully, only hints |
| `warnings` | Compiled successfully, warnings present |
| `error` | Compilation failed |
| `invalid` | Bad command-line arguments |
| `internal_error` | Unexpected failure (MSBuild not found, etc.) |

## Configuration

The compiler auto-detects RAD Studio from the Windows registry. To override or configure optional features, create a `delphi-compiler.env` file next to the executable:

```env
# Required: path to rsvars.bat (auto-detected from registry if not set)
RSVARS_PATH=C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat

# Optional: path to delphi-lookup.exe for symbol resolution
DELPHI_LOOKUP_PATH=C:\Tools\delphi-lookup.exe

# Optional: path to a file index for resolving missing unit files
FILE_INDEX_PATH=C:\.public\.file-index.txt

# Optional: always output Linux-style paths
WSL=true
```

Settings can also be provided as environment variables (environment variables take precedence over the `.env` file).

### Multiple Delphi versions

To select a specific RAD Studio version, set `RSVARS_PATH` to its `rsvars.bat`. If only one version is installed, it is auto-detected. If multiple are found, you must set the path explicitly.

| Delphi | Codename | Studio version |
|--------|----------|---------------|
| 13 | Florence | 37.0 |
| 12 | Athens | 23.0 |
| 11 | Alexandria | 22.0 |
| 10.4 | Sydney | 21.0 |
| 10.3 | Rio | 20.0 |

Example for Delphi 11:

```env
RSVARS_PATH=C:\Program Files (x86)\Embarcadero\Studio\22.0\bin\rsvars.bat
```

Or as a one-off environment variable:

```bash
RSVARS_PATH='C:\Program Files (x86)\Embarcadero\Studio\22.0\bin\rsvars.bat' delphi-compiler.exe MyProject.dproj
```

## Optional integrations

### delphi-lookup

If [delphi-lookup](https://github.com/JavierusTk/delphi-lookup) is present in the same directory (or configured via `DELPHI_LOOKUP_PATH`), the compiler will automatically look up undeclared identifiers (`E2003` errors) and include the results in the JSON output. This helps AI assistants determine which `uses` clause to add.

### File index

If a file index is available (a text file with one file path per line), missing file errors (`F1026`) will be looked up against it. By default the compiler looks for `.public/.file-index.txt` at the drive root of the project.

## Building from source

Requires RAD Studio 12 (Delphi 12 Athens) or later.

```bash
# Using MSBuild directly
msbuild delphi-compiler.dproj /p:Config=Release /p:Platform=Win32

# Or using delphi-compiler itself
delphi-compiler.exe delphi-compiler.dproj --config=Release
```

## Project structure

```
delphi-compiler.dpr           Main project file
Compilar.Args.pas             Command-line argument parsing
Compilar.Config.pas           Configuration (.env, registry, auto-detection)
Compilar.Context.pas          Source code context extraction for errors
Compilar.Lookup.pas           Symbol lookup integration (delphi-lookup, file index)
Compilar.MSBuild.pas          MSBuild invocation
Compilar.Output.pas           JSON output formatting
Compilar.Parser.pas           Compiler output parsing
Compilar.PathUtils.pas        Linux/Windows path conversion (WSL support)
Compilar.ProjectInfo.pas      .dproj parsing and output path resolution
Compilar.Types.pas            Type definitions
```

## License

MIT with Commons Clause. See [LICENSE](LICENSE).
