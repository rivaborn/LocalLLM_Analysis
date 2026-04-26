# file_helpers.ps1

File processing, presets, hashing, and display helpers. Dot-sourced by `llm_common.ps1`.

## What it is

Not a standalone script — a PowerShell module. It defines eleven functions plus one script-scoped variable (`$script:trivialPatterns`). It has no params block and no exit codes; everything is exposed as functions called from the worker scripts in `Analysis/`.

## Functions

| Function                | Purpose                                                                                                  |
| ----------------------- | -------------------------------------------------------------------------------------------------------- |
| `Get-SHA1`              | SHA1 hash of a file (used for incremental-rebuild caches)                                                |
| `Get-Preset`            | Resolve a named engine preset to include/exclude regexes + description + fence language                  |
| `Get-FenceLang`         | Map a file extension to a markdown fence language (e.g. `.cpp` → `cpp`)                                  |
| `Test-TrivialFile`      | Detect generated/auto/empty files that should get a stub doc instead of a full LLM analysis              |
| `Write-TrivialStub`     | Write a tiny placeholder doc for a trivial file                                                          |
| `Get-OutputBudget`      | Adaptive output-token budget (300–800) based on input file line count                                    |
| `Truncate-Source`       | Head + tail truncation with a marker, when source exceeds a max-line budget                              |
| `Resolve-ArchFile`      | Locate a file under `ARCHITECTURE_DIR` (cross-pipeline integration helper)                               |
| `Get-SerenaContextDir`  | Resolve `SERENA_CONTEXT_DIR` to an absolute path if it exists                                            |
| `Load-CompressedLSP`    | Extract the `## Symbol Overview` section from a `.serena_context.txt` file                               |
| `Show-SimpleProgress`   | Single-line progress display with rate and ETA, written via `\r` so it overwrites itself                 |

## Script-scoped state

| Variable                  | Purpose                                                                            |
| ------------------------- | ---------------------------------------------------------------------------------- |
| `$script:trivialPatterns` | Filename regex list for `Test-TrivialFile` (`.generated.h`, `.gen.cpp`, etc.)      |

---

## Get-SHA1

Compute the SHA-1 hash of a file as a lowercase hex string.

**Parameters:**

| Parameter   | Type   | Default | Effect                  |
| ----------- | ------ | ------- | ----------------------- |
| `$filePath` | string | (none)  | Path to the file to hash|

**Returns:** string — 40-character lowercase hex SHA-1.

Used by worker scripts to skip files whose source hash already matches the cached doc's hash, so re-running the pipeline only re-analyzes changed files.

```powershell
$h = Get-SHA1 'REDALERT/object.cpp'  # "3a7c1b9..."
```

---

## Get-Preset

Resolve a preset name to a hashtable of file-walking parameters.

**Parameters:**

| Parameter | Type   | Default | Effect                                                                                          |
| --------- | ------ | ------- | ----------------------------------------------------------------------------------------------- |
| `$name`   | string | (none)  | Preset alias. Case-insensitive. Empty string `''` returns the generic default preset.           |

**Returns:** hashtable with four keys:

| Key       | Type   | Meaning                                                                            |
| --------- | ------ | ---------------------------------------------------------------------------------- |
| `Include` | regex  | Files whose path matches this regex are included                                   |
| `Exclude` | regex  | Files whose path matches this regex are excluded (applied after Include)           |
| `Desc`    | string | Human-readable codebase description, used as a fallback for `CODEBASE_DESC`        |
| `Fence`   | string | Default markdown fence language for this preset's source files                     |

**Supported presets:**

| Preset alias                         | Fence    | Description                                                  |
| ------------------------------------ | -------- | ------------------------------------------------------------ |
| `quake` / `quake2` / `quake3` / `doom` / `idtech` | `c`      | id Software / Quake-family C engines                         |
| `unreal` / `ue4` / `ue5`             | `cpp`    | Unreal Engine C++/C# source                                  |
| `godot`                              | `cpp`    | Godot engine (C++/GDScript/C#)                               |
| `unity`                              | `csharp` | Unity (C#/shaders)                                           |
| `source` / `valve`                   | `cpp`    | Source Engine (Valve / C++)                                  |
| `rust`                               | `rust`   | Rust game engines                                            |
| `python` / `py`                      | `python` | Python codebases (excludes `.venv`, `__pycache__`, etc.)     |
| `generals` / `cnc` / `sage`          | `cpp`    | C&C Generals / Zero Hour (SAGE) and Remastered TD/RA source  |
| `''` (empty)                         | `c`      | Generic catch-all for mixed C/C++/C#/Java/Py/Rust/Lua/etc.   |

**Throws:** prints `"Unknown preset: <name>"` to stderr and `exit 2` if the name is not recognized.

```powershell
$p = Get-Preset 'cnc'
$includeRx = $p.Include  # '\.(cpp|h|hpp|c|cc|cxx|inl|inc)$'
$fence     = $p.Fence    # 'cpp'
```

Worker scripts typically allow `.env` to override per-preset defaults via `INCLUDE_EXT_REGEX` and `EXCLUDE_DIRS_REGEX`:

```powershell
$presetData = Get-Preset (Cfg 'PRESET' '')
$includeRx  = Cfg 'INCLUDE_EXT_REGEX'  $presetData.Include
$excludeRx  = Cfg 'EXCLUDE_DIRS_REGEX' $presetData.Exclude
```

---

## Get-FenceLang

Map a file extension to a markdown fence-language tag.

**Parameters:**

| Parameter | Type   | Default | Effect                                                          |
| --------- | ------ | ------- | --------------------------------------------------------------- |
| `$file`   | string | (none)  | File path or filename (only the extension is inspected)         |
| `$def`    | string | (none)  | Default fence language returned when the extension is unknown   |

**Mapping:**

| Extension                                        | Fence language |
| ------------------------------------------------ | -------------- |
| `.c`, `.h`, `.inc`                               | `c`            |
| `.cpp`, `.cc`, `.cxx`, `.hpp`, `.hh`, `.hxx`, `.inl` | `cpp`      |
| `.cs`                                            | `csharp`       |
| `.java`                                          | `java`         |
| `.py`                                            | `python`       |
| `.rs`                                            | `rust`         |
| `.lua`                                           | `lua`          |
| `.gd`, `.gdscript`                               | `gdscript`     |
| `.swift`                                         | `swift`        |
| `.m`, `.mm`                                      | `objectivec`   |
| `.shader`, `.cginc`, `.hlsl`, `.glsl`, `.compute`| `hlsl`         |
| `.toml`                                          | `toml`         |
| `.tscn`, `.tres`                                 | `ini`          |
| anything else                                    | `$def`         |

**Returns:** string — fence language token suitable for triple-backtick code blocks.

```powershell
$lang = Get-FenceLang 'src/foo.cpp' 'cpp'  # 'cpp'
$lang = Get-FenceLang 'README.md'   'cpp'  # 'cpp' (unknown ext → default)
```

---

## Test-TrivialFile

Decide whether a file is "trivial" — auto-generated, near-empty, or pure includes — and should get a stub doc instead of a full LLM analysis.

**Parameters:**

| Parameter   | Type   | Default | Effect                                                            |
| ----------- | ------ | ------- | ----------------------------------------------------------------- |
| `$rel`      | string | (none)  | Relative path of the file (used for filename pattern matching)    |
| `$fullPath` | string | (none)  | Absolute path used to read the file                               |
| `$minLines` | int    | (none)  | Minimum line count threshold; files below this are trivial        |

**Returns true when:**

- Filename matches one of `$script:trivialPatterns`: `.generated.h$`, `.gen.cpp$`, `^Module\.[A-Za-z0-9_]+\.cpp$`, `Classes\.h$`
- File has fewer than `$minLines` total lines
- File has at most 2 non-blank, non-comment, non-`#include`, non-`#pragma`, non-`#ifndef`, non-`#define`, non-`#endif` lines (i.e. nothing meaningful beyond preprocessor)

**Returns:** boolean.

```powershell
if (Test-TrivialFile $rel $fullPath 20) {
    Write-TrivialStub $rel $outPath
} else {
    # full LLM analysis
}
```

---

## Write-TrivialStub

Write a 4-line placeholder doc for a trivial file.

**Parameters:**

| Parameter  | Type   | Default | Effect                                                |
| ---------- | ------ | ------- | ----------------------------------------------------- |
| `$rel`     | string | (none)  | Relative path; used as the doc's `# <heading>` title  |
| `$outPath` | string | (none)  | Output `.md` path; written as UTF-8                   |

**Returns:** `$null`. Side effect: writes the file.

**Output format:**

```markdown
# <rel>

## Purpose
Auto-generated or trivial file. No detailed analysis needed.

## Responsibilities
- Boilerplate / generated code
```

---

## Get-OutputBudget

Pick an output-token budget proportional to input size. Caller passes the source file's line count; gets back a `num_predict`/`max_tokens` value to send to `Invoke-LocalLLM`.

**Parameters:**

| Parameter    | Type | Default | Effect                                  |
| ------------ | ---- | ------- | --------------------------------------- |
| `$lineCount` | int  | (none)  | Number of lines in the source file      |

**Tiers:**

| Source lines | Output budget |
| ------------ | ------------- |
| `< 50`       | `300`         |
| `< 200`      | `400`         |
| `< 500`      | `600`         |
| `>= 500`     | `800`         |

**Returns:** int.

Tiny files don't need 800 tokens of explanation; large files do. Tuning these tiers is a one-line edit in `file_helpers.ps1`.

---

## Truncate-Source

Clip a source-file line array to fit a max-line budget by keeping the head and tail and inserting a marker in the middle. No-op if the source already fits.

**Parameters:**

| Parameter   | Type      | Default | Effect                                                                |
| ----------- | --------- | ------- | --------------------------------------------------------------------- |
| `$srcLines` | string[]  | (none)  | Source file content as a line array                                   |
| `$maxLines` | int       | (none)  | Maximum allowed line count. `<= 0` or `>= length` returns input as-is |

**Returns:** string — the (possibly-truncated) source joined by `` `n ``.

**Format when truncated:** first `floor(maxLines/2)` lines, then a comment marker, then last `floor(maxLines/2)` lines:

```
<head lines...>

/* ... TRUNCATED: showing first N and last N of TOTAL lines ... */

<tail lines...>
```

```powershell
$src = Get-Content $file
$body = Truncate-Source $src 800
```

---

## Resolve-ArchFile

Look up a file under `ARCHITECTURE_DIR` (set in `.env`). Used by the planned Debug pipeline to consume Analysis outputs without hardcoding paths. Returns empty string if the env key is unset, the file doesn't exist, or the directory doesn't exist.

**Parameters:**

| Parameter  | Type   | Default | Effect                                                                                                |
| ---------- | ------ | ------- | ----------------------------------------------------------------------------------------------------- |
| `-Name`    | string | (none)  | Filename to look for under `ARCHITECTURE_DIR` (e.g. `'xref_index.md'`, `'architecture.md'`)           |
| `-BaseDir` | string | `''`    | Base directory used when `ARCHITECTURE_DIR` is relative. Empty means use `(Get-Location).Path` (CWD). |

**Returns:** string — absolute resolved path, or `''` if not found / not configured.

```powershell
$xref = Resolve-ArchFile -Name 'xref_index.md'
if ($xref) {
    $xrefContent = Get-Content $xref -Raw
}
```

---

## Get-SerenaContextDir

Resolve `SERENA_CONTEXT_DIR` from `.env` to an absolute directory path if it exists.

**Parameters:**

| Parameter  | Type   | Default | Effect                                                                       |
| ---------- | ------ | ------- | ---------------------------------------------------------------------------- |
| `-BaseDir` | string | `''`    | Base directory for relative `SERENA_CONTEXT_DIR`. Empty means CWD.           |

**Returns:** string — absolute path of an existing directory, or `''` if `SERENA_CONTEXT_DIR` is unset or the directory doesn't exist.

```powershell
$ctxDir = Get-SerenaContextDir
$ctx    = Load-CompressedLSP $ctxDir 'REDALERT/object.cpp'
```

---

## Load-CompressedLSP

Read a `.serena_context.txt` file and return only the `## Symbol Overview` section. Used to inject a compact symbol summary into LLM prompts without passing the entire LSP context dump.

**Parameters:**

| Parameter           | Type   | Default | Effect                                                                                       |
| ------------------- | ------ | ------- | -------------------------------------------------------------------------------------------- |
| `$serenaContextDir` | string | (none)  | Absolute path to the serena context directory (typically from `Get-SerenaContextDir`)        |
| `$rel`              | string | (none)  | Relative source path (forward or back slashes); appended with `.serena_context.txt`          |

**Returns:** string — the `## Symbol Overview` section (header included), trimmed. Returns `''` if the dir is empty, the per-file context is missing, the file is empty, or the section header isn't present.

**File-name convention:** for source `REDALERT/foo.cpp` it looks for `<serenaContextDir>\REDALERT\foo.cpp.serena_context.txt`.

---

## Show-SimpleProgress

Render a single-line progress indicator with rate and ETA. Uses carriage return (`\r`) so it overwrites itself on each call. The orchestrator (`AnalysisPipeline.py`) recognizes `PROGRESS:` lines and re-emits them in place to avoid scrollback spam.

**Parameters:**

| Parameter    | Type     | Default | Effect                                                                  |
| ------------ | -------- | ------- | ----------------------------------------------------------------------- |
| `$done`      | int      | (none)  | Items processed so far                                                  |
| `$total`     | int      | (none)  | Total items to process                                                  |
| `$startTime` | datetime | (none)  | When the loop started (used to compute rate; pass `[datetime]::Now`)    |

**Returns:** `$null`. Side effect: writes one carriage-return-prefixed line to the console.

**Output format:**

```
PROGRESS: 27/154  rate=0.42/s  eta=0h05m02s
```

ETA is formatted as `<H>h<MM>m<SS>s` when computable; `?` when rate is zero or unknown. Line is right-padded to 80 chars to overwrite any prior shorter line.

```powershell
$start = [datetime]::Now
for ($i = 0; $i -lt $files.Count; $i++) {
    Show-SimpleProgress ($i + 1) $files.Count $start
    # ... work ...
}
```

---

## Related

- `Common/llm_common.ps1` — shim that loads this module
- `Common/llm_core.ps1` — companion module (LLM client + env parsing)
- `Common/.env` — `PRESET`, `INCLUDE_EXT_REGEX`, `EXCLUDE_DIRS_REGEX`, `MIN_TRIVIAL_LINES`, `MAX_FILE_LINES`, `ARCHITECTURE_DIR`, `SERENA_CONTEXT_DIR` are all consumed by functions here
- `Documentation/llm_common.md` — overview of the shim
- `Documentation/llm_core.md` — companion module
