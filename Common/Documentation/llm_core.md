# llm_core.ps1

LLM invocation and environment infrastructure for the toolkit. Dot-sourced by `llm_common.ps1`.

## What it is

Not a standalone script — a PowerShell module. It defines six functions that worker scripts use to talk to the local Ollama server, parse `.env` files, look up config values, resolve role-specific model names, and detect a clean cancellation request. It has no params block and no exit codes; everything is exposed as functions.

## Functions

| Function           | Purpose                                                                                                          |
| ------------------ | ---------------------------------------------------------------------------------------------------------------- |
| `Get-LLMEndpoint`  | Resolve the Ollama HTTP endpoint URL                                                                             |
| `Get-LLMModel`     | Resolve a model name through the role-key → `LLM_DEFAULT_MODEL` → fallback chain                                 |
| `Test-CancelKey`   | Poll keyboard for Ctrl+Q and exit cleanly if pressed                                                             |
| `Invoke-LocalLLM`  | Call Ollama (native `/api/chat` or OpenAI-compatible `/v1/chat/completions`) with retry, thinking-mode support   |
| `Read-EnvFile`     | Parse a `.env` file into a `[hashtable]`                                                                         |
| `Cfg`              | Look up a key in the script-scoped `$script:cfg` hashtable with a default                                        |

---

## Get-LLMEndpoint

Resolve the Ollama endpoint URL via this precedence chain:

1. `$env:LLM_ENDPOINT` environment variable
2. `LLM_ENDPOINT` key from `.env` (read via `Cfg`)
3. `http://${LLM_HOST}:${LLM_PORT}` composed from `LLM_HOST` and `LLM_PORT` keys
4. Falls back to `http://192.168.1.126:11434` if neither is set

**Parameters:** none.
**Returns:** string — endpoint URL with trailing slash stripped.
**Side effects:** none.

```powershell
$endpoint = Get-LLMEndpoint  # e.g. "http://192.168.1.126:11434"
```

---

## Get-LLMModel

Resolve a model name via the role-specific → default → fallback chain. Lets `.env` set one universal default and only override per-role when a specific role needs a different model.

| Parameter   | Type   | Default            | Effect                                                                                                                                       |
| ----------- | ------ | ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `-RoleKey`  | string | `''`               | Name of the role-specific config key to check first (e.g. `'LLM_MODEL'`, `'LLM_PLANNING_MODEL'`). Empty means skip the role-specific lookup. |
| `-Fallback` | string | `'qwen3-coder:30b'`| Hardcoded last-resort model name when neither the role key nor `LLM_DEFAULT_MODEL` is set.                                                   |

**Resolution order:**

1. If `-RoleKey` is non-empty and `Cfg <RoleKey>` returns a non-empty value, use it.
2. Else if `LLM_DEFAULT_MODEL` is set in `.env`, use it.
3. Else use `-Fallback`.

`Cfg` already treats empty strings as unset, so leaving `LLM_MODEL=` in `.env` (key present, value blank) documents the key without overriding the default — exactly what you want for a self-documenting config.

**Returns:** string — model name suitable for passing as `-Model` to `Invoke-LocalLLM`.

```powershell
$llmModel = Get-LLMModel -RoleKey 'LLM_MODEL'
$plan     = Get-LLMModel -RoleKey 'LLM_PLANNING_MODEL'
```

---

## Test-CancelKey

Poll the console for Ctrl+Q. If pressed, prints a yellow message and `exit 130` (the conventional exit code for SIGINT-style user cancellation). Returns silently if input is redirected (non-interactive) or if no key is queued.

**Parameters:** none.
**Returns:** `$null` (early-returns on no-input or non-interactive).
**Side effects:** consumes keys from the console buffer; calls `exit 130` if Ctrl+Q is found.

Worker scripts should call this between LLM invocations inside long loops:

```powershell
foreach ($file in $files) {
    Test-CancelKey
    Invoke-LocalLLM -SystemPrompt $sys -UserPrompt $usr -Model $m
    ...
}
```

Pressing Ctrl+Q inside such a loop terminates the script cleanly between iterations rather than mid-LLM-call.

---

## Invoke-LocalLLM

Send a chat-completion request to Ollama. Picks one of two API endpoints based on `-NumCtx`:

- **`-NumCtx > 0`** → `POST /api/chat` (Ollama-native; supports `options.num_ctx` and reasoning-model thinking)
- **`-NumCtx <= 0`** → `POST /v1/chat/completions` (OpenAI-compatible)

| Parameter        | Type    | Default              | Effect                                                                                                                                                                                                |
| ---------------- | ------- | -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `-SystemPrompt`  | string  | (none)               | Optional system message. Skipped when empty/whitespace.                                                                                                                                               |
| `-UserPrompt`    | string  | (none)               | The user message. Required.                                                                                                                                                                           |
| `-Endpoint`      | string  | `''`                 | Full endpoint URL. When empty, calls `Get-LLMEndpoint`.                                                                                                                                               |
| `-Model`         | string  | `'qwen2.5-coder:14b'`| Model name. Callers normally pass `Get-LLMModel -RoleKey 'LLM_MODEL'` here.                                                                                                                           |
| `-Temperature`   | double  | `0.1`                | Sampling temperature.                                                                                                                                                                                 |
| `-MaxTokens`     | int     | `800`                | Max output tokens (`num_predict` for `/api/chat`, `max_tokens` for `/v1`).                                                                                                                            |
| `-NumCtx`        | int     | `-1`                 | Context window size. `-1` reads `LLM_NUM_CTX` from `.env` (via `Cfg`). `0` means "use OpenAI-compat endpoint, no `num_ctx`". `> 0` switches to native `/api/chat` and passes the value as `options.num_ctx`. |
| `-Timeout`       | int     | `120`                | Per-request timeout in seconds.                                                                                                                                                                       |
| `-MaxRetries`    | int     | `3`                  | Total attempts before raising. Retries on any `Invoke-RestMethod` error.                                                                                                                              |
| `-RetryDelay`    | int     | `5`                  | Sleep seconds between retries.                                                                                                                                                                        |
| `-Think`         | bool    | `$false`             | When `$true` and `-NumCtx > 0`, sets `think: true` in the request body so reasoning models emit `message.thinking` separately from `message.content`. Ignored when `-NumCtx <= 0`.                    |
| `-ThinkingFile`  | string  | `''`                 | When non-empty and the response includes `message.thinking`, writes the reasoning chain to this path as UTF-8. Use for audit/debug sidecars.                                                          |

**Returns:** string — trimmed assistant content from the response.

**Throws:**

- `"Empty response from LLM"` — response had no content. If thinking was enabled and produced output, the message instead reads `"Model exhausted budget inside <thinking> (thinking=N chars, num_predict=M). Raise LLM_PLANNING_MAX_TOKENS."` so the operator knows exactly which knob to turn.
- `"LLM returned suspiciously short/garbled content (N chars: '...')"` — output is < 20 chars or has no ASCII letters/digits. With thinking enabled, the message appends `"-- thinking=N chars suggests budget exhaustion during reasoning."`.
- `"LLM call failed after N attempts: <inner message>"` — every retry exhausted.

**Body shape (NumCtx > 0):**

```json
{
  "model": "<model>",
  "messages": [{"role": "system", ...}, {"role": "user", ...}],
  "stream": false,
  "options": { "num_ctx": <NumCtx>, "temperature": <Temperature>, "num_predict": <MaxTokens> },
  "think": true   // only if -Think
}
```

**Body shape (NumCtx <= 0):**

```json
{
  "model": "<model>",
  "messages": [...],
  "stream": false,
  "temperature": <Temperature>,
  "max_tokens": <MaxTokens>
}
```

**Example:**

```powershell
$resp = Invoke-LocalLLM `
    -SystemPrompt $sysPrompt `
    -UserPrompt   $usrPrompt `
    -Model        (Get-LLMModel -RoleKey 'LLM_MODEL') `
    -Temperature  ([double](Cfg 'LLM_TEMPERATURE' '0.1')) `
    -MaxTokens    1024 `
    -Timeout      ([int](Cfg 'LLM_TIMEOUT' '300'))
```

---

## Read-EnvFile

Parse a `.env` file. One pass; preserves no order.

**Parameters:**

| Parameter | Type   | Default | Effect                          |
| --------- | ------ | ------- | ------------------------------- |
| `$path`   | string | (none)  | Filesystem path to the env file |

**Behavior:**

- Skips blank lines and lines whose first non-space char is `#`.
- Matches `KEY=VALUE` (anything before the first `=` is the key, anything after is the value).
- Trims surrounding double or single quotes from the value (one set only).
- Replaces literal `$HOME` and a leading `~` with `$env:USERPROFILE` so paths like `~/repo` and `$HOME/repo` resolve on Windows.
- Returns an empty hashtable if the file doesn't exist (no error).

**Returns:** `[hashtable]` keyed by env var name.

```powershell
$script:cfg = Read-EnvFile (Join-Path $PSScriptRoot '..\Common\.env')
```

The result is conventionally assigned to `$script:cfg` so that `Cfg` can find it.

---

## Cfg

Look up a key in `$script:cfg` (the hashtable produced by `Read-EnvFile`) with a default. Empty strings count as unset.

**Parameters:**

| Parameter   | Type   | Default | Effect                                          |
| ----------- | ------ | ------- | ----------------------------------------------- |
| `$key`      | string | (none)  | Config key name to look up                      |
| `$default`  | string | `''`    | Value returned when the key is missing or empty |

**Returns:** the config value, or `$default` if the key is absent / blank.

**Requires:** `$script:cfg` to be set in the calling script (typically via `$script:cfg = Read-EnvFile $EnvFile`).

```powershell
$temperature = [double](Cfg 'LLM_TEMPERATURE' '0.1')
$timeout     = [int]   (Cfg 'LLM_TIMEOUT'     '120')
$preset      =          Cfg 'PRESET'          ''
```

---

## Related

- `Common/llm_common.ps1` — shim that loads this module
- `Common/file_helpers.ps1` — file utilities loaded alongside this module
- `Common/.env` — every config key documented above is read from here via `Read-EnvFile` + `Cfg`
- `Documentation/llm_common.md` — overview of the shim
- `Documentation/file_helpers.md` — companion module
