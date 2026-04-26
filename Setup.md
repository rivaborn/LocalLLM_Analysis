# Architecture Analysis Toolkit -- Setup & Usage Guide

Automated architecture documentation for game engine codebases using a local Ollama LLM server, with optional clangd LSP. All scripts live in `ArchAnalysis/` and are run from the repo root.

---

## Table of Contents

1. [Complete Pipeline](#1-complete-pipeline)
2. [Prerequisites](#2-prerequisites)
3. [Installation](#3-installation)
4. [Configuration (.env)](#4-configuration-env)
5. [clangd / LSP Setup (Optional)](#5-clangd--lsp-setup-optional)
6. [Running the Pipeline](#6-running-the-pipeline)
7. [Presets](#7-presets)
8. [Example: CnC Remastered Collection Pipeline](#8-example-cnc-remastered-collection-pipeline)
9. [Output Directory Structure](#9-output-directory-structure)
10. [Resumability](#10-resumability)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Complete Pipeline

```
  (optional)
  python ArchAnalysis\generate_compile_commands.py    compile_commands.json
  .\ArchAnalysis\serena_extract.ps1                   .serena_context/ (free, builds clangd index on first run)
                          |
  Source files --> .\ArchAnalysis\archgen_local.ps1 --> Per-file .md docs
                          |
            +-------------+-------------+
            v             v             v
   archxref.ps1    archgraph.ps1   arch_overview_local.ps1
        |              |                    |
        v              v                    v
   xref_index.md  callgraph.mermaid   architecture.md
        |                                   |
        +-------------- + -----------------+
                        |
               archpass2_context.ps1  (free)
                        |
               archpass2_local.ps1 --> .pass2.md docs
```

| Step | Script                                       | LLM Calls  | Output                       |
|------|----------------------------------------------|------------|------------------------------|
| 0    | `.\ArchAnalysis\serena_extract.ps1`          | 0 (free)   | LSP symbols + references     |
| 1    | `.\ArchAnalysis\archgen_local.ps1`           | 1 per file | Per-file architecture docs   |
| 2    | `.\ArchAnalysis\archxref.ps1`                | 0 (free)   | Cross-reference index        |
| 3    | `.\ArchAnalysis\archgraph.ps1`               | 0 (free)   | Mermaid diagrams             |
| 4    | `.\ArchAnalysis\arch_overview_local.ps1`     | N+1        | Architecture overview        |
| 4b   | `.\ArchAnalysis\archpass2_context.ps1`       | 0 (free)   | Targeted context             |
| 5    | `.\ArchAnalysis\archpass2_local.ps1`         | 1 per file | Enriched analysis            |

---

## 2. Prerequisites

### Required

- **PowerShell 5.1+** (Windows)
- **Ollama** installed and running with a code model pulled (e.g., `ollama pull qwen2.5-coder:14b`)
- Network access from workstation to Ollama server

### Optional (for LSP extraction)

- **Python 3.12** via `uv python install 3.12`
- **clangd** (C++ language server)
  - Via VS Community Edition: `C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\Llvm\x64\bin\clangd.exe`
  - Or: `winget install LLVM.LLVM`
- **compile_commands.json** at repo root -- generate with `generate_compile_commands.py`, which parses `.vcxproj`/`.vcproj`/`.dsp` directly or delegates to `cmake`/`meson`/`ninja`/`bazel` if their config files sit at the repo root
- No separate clangd index-building step needed -- `serena_extract.ps1` builds it on-the-fly

---

## 3. Installation

```powershell
cd C:\path\to\your\game-engine-repo

# Copy ArchAnalysis directory (or clone the toolkit repo)
Copy-Item -Recurse C:\path\to\toolkit\ArchAnalysis .

# Create ArchAnalysis\.env (alongside the scripts -- NOT at the repo root)
# See Section 4 for the full template.

# Add generated artifacts to .gitignore
Add-Content .gitignore "`nArchAnalysis\.env`narchitecture/`ncompile_commands.json"
```

---

## 4. Configuration (.env)

Create `.env` in `ArchAnalysis/` (alongside the scripts, **not** at the repo root). Scripts read it from `$PSScriptRoot`.

```env
LLM_HOST=192.168.1.126
LLM_PORT=11434
LLM_MODEL=qwen2.5-coder:14b
LLM_TEMPERATURE=0.1
LLM_MAX_TOKENS=800
LLM_TIMEOUT=120

PRESET=cnc
CODEBASE_DESC="Command & Conquer Remastered Collection source release (original TD 1995 + RA 1996 C++ DLL source + C# map editor)"
MAX_FILE_LINES=800
SKIP_TRIVIAL=1

# Extend the cnc preset so the C# map editor is picked up and build dirs are skipped.
INCLUDE_EXT_REGEX=\.(cpp|h|hpp|c|cc|cxx|inl|inc|cs)$
EXCLUDE_DIRS_REGEX=[/\\](\.git|architecture|Debug|Release|x64|Win32|\.vs|bin|obj|Steamworks\.NET)([/\\]|$)
```

The `.env` file also supports a `#Subsections begin` / `#Subsections end` block listing subdirectories for `ArchPipeline.py` to process in sequence. Comment lines (e.g. `# 530 files`) are ignored by the parser and can annotate file counts per subsection. See `Instructions.md` Section 11 for all variables.

---

## 5. clangd / LSP Setup (Optional)

LSP extraction enriches Pass 1 docs with accurate symbol information. The pipeline works without it.

### Step 1: Generate compile_commands.json

```powershell
python ArchAnalysis\generate_compile_commands.py
```

The generator discovers whatever build artifacts are present and picks the best source, in this order:

1. **Pre-existing `compile_commands.json`** anywhere under the root (e.g. from a prior `cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON` run in `build/`) -- copied verbatim.
2. **Native Visual Studio / Visual C++ project files** parsed directly: `.vcxproj` (MSBuild, VS 2010+), `.vcproj` (VS 2002-2008), `.dsp` (VC6). Release-style configs are preferred; include dirs, preprocessor defs, and source lists are pulled per project. `.sln` files are reported for visibility.
3. **Delegate** to `cmake`/`meson`/`ninja`/`bazel` when their config files sit at the repo root. If the required tool (or its backend) is not on `PATH`, the script stops and prints the install URL.

For the CnC Remastered Collection source release, it parses `REDALERT/RedAlert.vcxproj` and `TIBERIANDAWN/TiberianDawn.vcxproj` directly (486 TUs total). The C# `CnCTDRAMapEditor/` tree is skipped -- clangd is C++-only.

### Step 2: Configure clangd

Create `.clangd` at repo root:
```yaml
Index:
  Background: Build
  StandardLibrary: No

Diagnostics:
  Suppress: ["*"]
  ClangTidy: false
```

### Step 3: Add clangd to PATH (if needed)

```powershell
$env:PATH += ";C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\Llvm\x64\bin"
```

### Step 4: Run LSP extraction

```powershell
.\ArchAnalysis\serena_extract.ps1 -Preset cnc
```

No separate index-building step is needed. clangd builds its background index on-the-fly during the first extraction run (this makes the first run slower). The index caches at `.cache/clangd/index/` and subsequent runs are faster.

Output: `ArchAnalysis/.serena_context/` -- auto-detected by `archgen_local.ps1`.

---

## 6. Running the Pipeline

All scripts are run from the repo root:

```powershell
.\ArchAnalysis\archgen_local.ps1 -Preset cnc
.\ArchAnalysis\archxref.ps1
.\ArchAnalysis\archgraph.ps1
.\ArchAnalysis\arch_overview_local.ps1
.\ArchAnalysis\archpass2_context.ps1
.\ArchAnalysis\archpass2_local.ps1 -Top 100
```

See `Instructions.md` for full parameters for each script.

---

## 7. Presets

| Preset                       | Languages              | Description                                        |
|------------------------------|------------------------|----------------------------------------------------|
| `generals` / `cnc` / `sage` | `.cpp .h .c .inl .inc` | C&C: Generals/Zero Hour + TD/RA Remastered src     |
| `quake` / `doom` / `idtech` | `.c .h .cpp .inl .inc` | id Software / Quake-family |
| `unreal` / `ue4` / `ue5`   | `.cpp .h .hpp .cs`     | Unreal Engine              |
| `godot`                      | `.cpp .h .gd .cs`     | Godot                      |
| `unity`                      | `.cs .shader .hlsl`   | Unity                      |
| `source` / `valve`          | `.cpp .h .c .vpc`     | Source Engine              |
| `rust`                       | `.rs .toml`           | Rust engines               |

---

## 8. Example: CnC Remastered Collection Pipeline

### By subsection (recommended for first run)

```powershell
# C++ game DLLs (each recursively includes its WIN32LIB/ subdir)
.\ArchAnalysis\archgen_local.ps1 -TargetDir REDALERT -Preset cnc
.\ArchAnalysis\archgen_local.ps1 -TargetDir TIBERIANDAWN -Preset cnc

# C# map editor
.\ArchAnalysis\archgen_local.ps1 -TargetDir CnCTDRAMapEditor -Preset cnc

# Cross-refs + overview
.\ArchAnalysis\archxref.ps1
.\ArchAnalysis\archgraph.ps1
.\ArchAnalysis\arch_overview_local.ps1

# Pass 2 on key files
.\ArchAnalysis\archpass2_context.ps1
.\ArchAnalysis\archpass2_local.ps1 -Top 100
```

Alternatively, `python ArchAnalysis\ArchPipeline.py` walks the subsection list in `.env` and runs all of the above end-to-end.

### Approximate sizes

| Subsection         | Files                                  |
|--------------------|----------------------------------------|
| `REDALERT`         | ~530 at root + 79 in `WIN32LIB/`       |
| `TIBERIANDAWN`     | ~307 at root + 82 in `WIN32LIB/`       |
| `CnCTDRAMapEditor` | 257 C# files                           |

Throughput: ~0.11 files/sec with `qwen2.5-coder:14b` on an RTX 3090 (~9s per file).

---

## 9. Output Directory Structure

```
architecture/
  REDALERT/
    CONQUER.CPP.md                           Pass 1 doc
    CONQUER.CPP.pass2.md                     Pass 2 doc
    WIN32LIB/ALLOC.CPP.md                    Nested subdir mirrors source layout
  TIBERIANDAWN/
    ...
  CnCTDRAMapEditor/
    ...
  .pass2_context/                            Targeted Pass 2 context
  .archgen_state/hashes.tsv                  Pass 1 resumability state
  .pass2_state/hashes.tsv                    Pass 2 resumability state
  architecture.md                            Synthesized overview
  xref_index.md                              Cross-reference index
  callgraph.md                               Mermaid diagrams

ArchAnalysis/
  .serena_context/                           LSP extraction output (optional)
```

---

## 10. Resumability

All scripts are incremental. Interrupt with Ctrl+C and re-run to continue. SHA1 hashes track which files are done.

---

## 11. Troubleshooting

### Ollama server unreachable

```powershell
curl http://192.168.1.126:11434/api/tags
```
Check `LLM_HOST` and `LLM_PORT` in `.env`.

### clangd not found

Add VS Community Edition's clangd to PATH:
```powershell
$env:PATH += ";C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\Llvm\x64\bin"
```

### Empty or garbled LLM responses

- Verify model is pulled: `ollama list` on the server
- Increase `LLM_TIMEOUT` for large files
- Reduce `MAX_FILE_LINES`

### Encoding issues

```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
```
