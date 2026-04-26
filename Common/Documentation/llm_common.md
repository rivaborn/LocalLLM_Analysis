# llm_common.ps1

Thin loader shim. Worker scripts in `Analysis/` dot-source this file; it loads both sub-modules so callers get the full API in one line.

## What it is

Not a standalone script — a PowerShell module that must be dot-sourced. It has no CLI parameters, no params block, no exit codes. Its sole responsibility is to load `llm_core.ps1` and `file_helpers.ps1` from the same directory.

## Source

```powershell
. (Join-Path $PSScriptRoot 'llm_core.ps1')
. (Join-Path $PSScriptRoot 'file_helpers.ps1')
```

That's the entire body. `$PSScriptRoot` resolves to whichever directory `llm_common.ps1` lives in, so the two sub-modules must sit alongside it.

## How worker scripts load it

Every PS1 in `Analysis/` does:

```powershell
. (Join-Path $PSScriptRoot '..\Common\llm_common.ps1')
```

After that line, every function below is in scope.

## API surface (loaded transitively)

The shim re-exports everything from both sub-modules. See the dedicated docs for full detail:

| Sub-module          | Doc                | Functions                                                                                                                                                                              |
| ------------------- | ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `llm_core.ps1`      | `llm_core.md`      | `Get-LLMEndpoint`, `Get-LLMModel`, `Test-CancelKey`, `Invoke-LocalLLM`, `Read-EnvFile`, `Cfg`                                                                                          |
| `file_helpers.ps1`  | `file_helpers.md`  | `Get-SHA1`, `Get-Preset`, `Get-FenceLang`, `Test-TrivialFile`, `Write-TrivialStub`, `Get-OutputBudget`, `Truncate-Source`, `Resolve-ArchFile`, `Get-SerenaContextDir`, `Load-CompressedLSP`, `Show-SimpleProgress` |

## Why a shim instead of a single file

`llm_common.ps1` started as a 327-line monolith. The split:

- `llm_core.ps1` — LLM invocation + environment infrastructure (model resolution, endpoint, env parsing, retries, thinking-mode dispatch, cancel key)
- `file_helpers.ps1` — file processing utilities (presets, hashing, fence-language mapping, trivial-file detection, truncation, LSP context loading, progress display)

The shim preserves the original load path — every existing `. .../llm_common.ps1` call site keeps working without modification. Add a new sub-module by appending one more dot-source line here.

## Verification

After loading, all public functions should resolve:

```powershell
. (Join-Path $PSScriptRoot '..\Common\llm_common.ps1')
Get-Command Invoke-LocalLLM, Get-LLMModel, Get-LLMEndpoint,
            Test-CancelKey, Read-EnvFile, Cfg,
            Get-SHA1, Get-Preset, Get-FenceLang,
            Test-TrivialFile, Write-TrivialStub,
            Get-OutputBudget, Truncate-Source,
            Resolve-ArchFile, Get-SerenaContextDir,
            Load-CompressedLSP, Show-SimpleProgress
```

All 17 should report `CommandType : Function`.

## Related

- `Common/llm_core.ps1` — LLM infrastructure (loaded first)
- `Common/file_helpers.ps1` — file/preset utilities (loaded second)
- `Common/.env` — config consumed by `Read-EnvFile` callers
- `Analysis/*.ps1` — every worker dot-sources this shim
