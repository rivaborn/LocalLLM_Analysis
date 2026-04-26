# CLAUDE.md -- Project Context

## Project Overview

Architecture documentation toolkit for game engine codebases. Generates per-file and subsystem-level architecture docs using a local Ollama LLM server, with optional LSP-powered semantic analysis via clangd.

**Target Codebase:** Command & Conquer Remastered Collection source release (EA/Westwood, open-sourced 2020). Contains the original C++ game logic for Tiberian Dawn (1995) and Red Alert (1996) as shipped in the Remastered Collection DLLs, plus a C# WinForms map editor.
**LLM Server:** Ollama at `LLM_HOST:LLM_PORT` (default `192.168.1.126:11434`)
**Model:** `qwen3-coder:30b` via `LLM_DEFAULT_MODEL` (any role-specific key falls back to this)

## Directory Layout

The toolkit is split into a shared module folder (`Common/`) and a pipeline folder (`Analysis/`). Drop the whole `LocalLLM_Analysis/` directory into the C&C repo root as a sibling of the source dirs.

```
<C&C repo root>/
  compile_commands.json    Generated compilation database (for clangd, optional)
  architecture/            Generated output (docs, xref, diagrams)
  LocalLLM_Analysis/       Toolkit
    Common/
      .env                 Pipeline configuration (LLM, preset, subsections)
      llm_common.ps1       Shim that dot-sources the two sub-modules
      llm_core.ps1         Invoke-LocalLLM, Get-LLMModel, Get-LLMEndpoint, Test-CancelKey, Read-EnvFile, Cfg
      file_helpers.ps1     Get-Preset, Get-FenceLang, Test-TrivialFile, Get-OutputBudget, Truncate-Source, Resolve-ArchFile, Get-SerenaContextDir, Load-CompressedLSP, Show-SimpleProgress, Get-SHA1
    Analysis/
      *.ps1                Worker scripts (each dot-sources ../Common/llm_common.ps1)
      *_prompt.txt         LLM system prompts
      AnalysisPipeline.py  Single-mode orchestrator
      generate_compile_commands.py
      serena_extract.py    LSP extraction backend
      conftest.py / test_archpipeline.py
      Documentation/       Per-script .md files
  REDALERT/                Red Alert (1996) C++ game source  (+ WIN32LIB/ subdir)
  TIBERIANDAWN/            Tiberian Dawn (1995) C++ game source  (+ WIN32LIB/ subdir)
  CnCTDRAMapEditor/        C# WinForms map editor for both games
  CnCRemastered.sln        Solution referencing RedAlert.vcxproj + TiberianDawn.vcxproj
  CnCTDRAMapEditor.sln     Solution for the C# map editor
```

Scripts are run from the C&C repo root: `.\LocalLLM_Analysis\Analysis\archgen_local.ps1 -Preset cnc`. Each PS1 finds `.env` at `..\Common\.env` relative to itself and uses `(Get-Location).Path` (or `git rev-parse`) as the repo root. Output goes to `architecture/` at the C&C repo root.

`AnalysisPipeline.py` reads `..\Common\.env` for subsection list and uses CWD as the repo root, so launch it from the C&C repo root: `python LocalLLM_Analysis\Analysis\AnalysisPipeline.py`.

## Pipeline Order

```
0 (free)   .\LocalLLM_Analysis\Analysis\serena_extract.ps1          LSP symbol data via clangd (optional)
1          .\LocalLLM_Analysis\Analysis\archgen_local.ps1            Per-file .md docs
2 (free)   .\LocalLLM_Analysis\Analysis\archxref.ps1                Cross-reference index
3 (free)   .\LocalLLM_Analysis\Analysis\archgraph.ps1               Mermaid call graph diagrams
4          .\LocalLLM_Analysis\Analysis\arch_overview_local.ps1      Subsystem architecture overview
4b (free)  .\LocalLLM_Analysis\Analysis\archpass2_context.ps1        Per-file targeted context
5          .\LocalLLM_Analysis\Analysis\archpass2_local.ps1          Selective re-analysis
```

## Key Configuration (`Common/.env`)

### LLM endpoint and models
- `LLM_HOST` and `LLM_PORT` -- composed into `http://HOST:PORT` (or set `LLM_ENDPOINT` directly for a one-line override)
- `LLM_DEFAULT_MODEL` -- universal fallback; every role-specific key below uses this when blank
- `LLM_MODEL` -- override for analysis worker scripts (`archgen_local`, `arch_overview_local`, `archpass2_local`)
- `LLM_PLANNING_MODEL` -- reserved for an optional reasoning model on synthesis stages
- `Get-LLMModel -RoleKey <key>` resolves: role-specific key → `LLM_DEFAULT_MODEL` → hardcoded fallback

### Inference parameters
- `LLM_TEMPERATURE`, `LLM_MAX_TOKENS`, `LLM_TIMEOUT` -- generic per-call settings
- `LLM_NUM_CTX` -- when > 0, `Invoke-LocalLLM` switches to Ollama's native `/api/chat` with `options.num_ctx` so the model gets the full window on every call. When 0/unset, falls back to `/v1/chat/completions`.
- `LLM_ANALYSIS_NUM_CTX` -- larger context for synthesis passes; analysis scripts promote this into `LLM_NUM_CTX` after loading config.
- `LLM_PLANNING_NUM_CTX`, `LLM_PLANNING_MAX_TOKENS`, `LLM_PLANNING_TIMEOUT` -- reasoning-model budgets (used only when a reasoning model is wired into a synthesis stage).

### Thinking mode
- `LLM_THINK=true` puts reasoning models in thinking mode (only effective when `LLM_NUM_CTX > 0`)
- `LLM_SAVE_THINKING=true` writes reasoning to `<output>.thinking.md` sidecars for audit
- `Invoke-LocalLLM` detects budget exhaustion inside `<thinking>` and emits an actionable error with the exact knob to raise.

### Codebase / file handling
- `PRESET=cnc` (alias of `generals`/`sage`)
- `INCLUDE_EXT_REGEX` / `EXCLUDE_DIRS_REGEX` -- preset overrides; currently extended with `.cs` (for `CnCTDRAMapEditor/`) and `bin|obj|Steamworks\.NET` excludes.
- `MAX_FILE_LINES=800` -- source truncation for limited context window
- `SKIP_TRIVIAL=1` / `MIN_TRIVIAL_LINES=20` -- skip generated/trivial files with stub docs
- `CHUNK_THRESHOLD=400` -- subsystem chunk size for `arch_overview_local`
- `#Subsections begin` / `#Subsections end` block lists subdirectories for `AnalysisPipeline.py` to process in sequence (currently `REDALERT`, `TIBERIANDAWN`, `CnCTDRAMapEditor`). Comment lines (e.g. `# 530 files`) are ignored.

### Cross-pipeline integration (commented out by default)
- `ARCHITECTURE_DIR` / `SERENA_CONTEXT_DIR` -- consumed by `Resolve-ArchFile` / `Get-SerenaContextDir` helpers, used by a future Debug pipeline. Not active in analysis-only runs.

## Architecture

- All scripts dot-source `Common/llm_common.ps1` (a 17-line shim that loads `llm_core.ps1` + `file_helpers.ps1`).
- Worker scripts find `.env` at `Join-Path $PSScriptRoot '..\Common\.env'`.
- Prompt `.txt` files load from `$PSScriptRoot` (same directory as the worker script).
- The three LLM-calling scripts (`archgen_local`, `arch_overview_local`, `archpass2_local`) promote `LLM_ANALYSIS_NUM_CTX` into `LLM_NUM_CTX` so `Invoke-LocalLLM` picks up the larger context window automatically.
- Single-threaded LLM processing (GPU handles one inference at a time).
- Text-processing scripts (`archxref.ps1`, `archgraph.ps1`, `archpass2_context.ps1`) have no LLM dependency.
- Press `Ctrl+Q` to cancel the current pipeline cleanly (handled by `Test-CancelKey` in `llm_core.ps1`).

## clangd / LSP (Optional)

- Generate `compile_commands.json` via: `python LocalLLM_Analysis\Analysis\generate_compile_commands.py`
- The generator discovers build artifacts in this order: (1) an existing `compile_commands.json`, (2) `.vcxproj` / `.vcproj` / `.dsp`, (3) delegate to `cmake` / `meson` / `ninja` / `bazel` if their config files are at the root (stops and prints an install URL if the required tool is missing).
- For this repo it parses `REDALERT/RedAlert.vcxproj` and `TIBERIANDAWN/TiberianDawn.vcxproj` directly (486 total translation units). The `CnCTDRAMapEditor/` is C# and is skipped (clangd is C++-only).
- clangd on VS Community Edition: `"C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\Llvm\x64\bin\clangd.exe"`
- No separate index-building step needed -- `serena_extract.ps1` spawns clangd which builds the index on-the-fly (first run is slower).
- Index cached at `.cache/clangd/index/` for faster subsequent runs.
- `serena_extract.ps1` produces `.serena_context.txt` files used by `archgen_local.ps1`.

## Documentation Files

Per-script docs live in `Analysis/Documentation/`:

- `archgen_local.md`
- `archxref.md`
- `archgraph.md`
- `arch_overview_local.md`
- `archpass2_context.md`
- `archpass2_local.md`
- `serena_extract.md` / `serena_extract_py.md`
- `generate_compile_commands.md`

## Presets

Defined in `Common/file_helpers.ps1`. Use `-Preset` flag or `PRESET` in `.env`.

| Preset                       | Description                                                        |
|------------------------------|--------------------------------------------------------------------|
| `generals` / `cnc` / `sage`  | C&C codebases: Generals/Zero Hour (SAGE) and TD/RA Remastered src  |
| `quake` / `doom` / `idtech`  | id Software / Quake-family                                         |
| `unreal` / `ue4` / `ue5`     | Unreal Engine                                                      |
| `godot`                      | Godot (C++/GDScript/C#)                                            |
| `unity`                      | Unity (C#/shaders)                                                 |
| `source` / `valve`           | Source Engine                                                      |
| `rust`                       | Rust engines (Bevy, etc.)                                          |
| `python` / `py`              | Python codebases                                                   |
