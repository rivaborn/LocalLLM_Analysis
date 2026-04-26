# ============================================================
# llm_common.ps1 -- Shared helper module for local LLM pipeline
#
# Dot-source this file from any local LLM script:
#   . (Join-Path $PSScriptRoot 'llm_common.ps1')
#
# Provides:
#   Invoke-LocalLLM    - Call Ollama OpenAI-compatible API
#   Get-LLMEndpoint    - Build endpoint URL from LLM_HOST + LLM_PORT
#   Read-EnvFile       - Parse .env key=value files
#   Get-SHA1           - SHA1 hash of a file
#   Get-Preset         - Engine preset definitions
#   Get-FenceLang      - Map file extension to markdown fence language
#   Test-TrivialFile   - Detect generated/trivial files
#   Write-TrivialStub  - Write a stub doc for trivial files
#   Get-OutputBudget   - Adaptive output token budget
# ============================================================

# ---------------------------------------------------------------------------
# Get-LLMEndpoint -- Build endpoint URL from LLM_HOST + LLM_PORT in .env
# ---------------------------------------------------------------------------

function Get-LLMEndpoint {
    $host_ = Cfg 'LLM_HOST' '192.168.1.126'
    $port  = Cfg 'LLM_PORT' '11434'
    return "http://${host_}:${port}"
}

# ---------------------------------------------------------------------------
# Invoke-LocalLLM -- Call Ollama via OpenAI-compatible chat completions API
# ---------------------------------------------------------------------------

function Invoke-LocalLLM {
    param(
        [string]$SystemPrompt,
        [string]$UserPrompt,
        [string]$Endpoint    = '',
        [string]$Model       = 'qwen2.5-coder:14b',
        [double]$Temperature = 0.1,
        [int]   $MaxTokens   = 800,
        [int]   $Timeout     = 120,
        [int]   $MaxRetries  = 3,
        [int]   $RetryDelay  = 5
    )

    if (-not $Endpoint -or $Endpoint -eq '') {
        $Endpoint = Get-LLMEndpoint
    }
    $uri = "$Endpoint/v1/chat/completions"

    $messages = @()
    if ($SystemPrompt -and $SystemPrompt.Trim() -ne '') {
        $messages += @{ role = 'system'; content = $SystemPrompt }
    }
    $messages += @{ role = 'user'; content = $UserPrompt }

    $body = @{
        model       = $Model
        messages    = $messages
        stream      = $false
        temperature = $Temperature
        max_tokens  = $MaxTokens
    } | ConvertTo-Json -Depth 5

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $resp = Invoke-RestMethod -Uri $uri `
                -Method Post `
                -ContentType 'application/json; charset=utf-8' `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
                -TimeoutSec $Timeout `
                -ErrorAction Stop

            $output = $resp.choices[0].message.content
            if (-not $output -or $output.Trim() -eq '') {
                throw "Empty response from LLM"
            }
            return $output.Trim()
        }
        catch {
            if ($attempt -ge $MaxRetries) {
                throw "LLM call failed after $MaxRetries attempts: $($_.Exception.Message)"
            }
            Write-Host "  [retry $attempt/$MaxRetries] $($_.Exception.Message)" -ForegroundColor Yellow
            Start-Sleep -Seconds $RetryDelay
        }
    }
}

# ---------------------------------------------------------------------------
# Read-EnvFile -- Parse a .env file into a hashtable
# ---------------------------------------------------------------------------

function Read-EnvFile($path) {
    $vars = @{}
    if (Test-Path $path) {
        Get-Content $path | ForEach-Object {
            $line = $_.Trim()
            if ($line -match '^#' -or $line -eq '') { return }
            if ($line -match '^([^=]+)=(.*)$') {
                $key = $Matches[1].Trim()
                $val = $Matches[2].Trim().Trim('"').Trim("'")
                $val = $val -replace [regex]::Escape('$HOME'), $env:USERPROFILE
                $val = $val -replace '^~', $env:USERPROFILE
                $vars[$key] = $val
            }
        }
    }
    return $vars
}

# ---------------------------------------------------------------------------
# Cfg -- Read a config key with a default fallback
# ---------------------------------------------------------------------------

function Cfg($key, $default = '') {
    if ($script:cfg.ContainsKey($key) -and $script:cfg[$key] -ne '') { return $script:cfg[$key] }
    return $default
}

# ---------------------------------------------------------------------------
# Get-SHA1 -- SHA1 hash of a file (for incremental skip logic)
# ---------------------------------------------------------------------------

function Get-SHA1($filePath) {
    $sha   = [System.Security.Cryptography.SHA1]::Create()
    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    return ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
}

# ---------------------------------------------------------------------------
# Get-Preset -- Engine preset definitions (include/exclude patterns)
# ---------------------------------------------------------------------------

function Get-Preset($name) {
    switch ($name.ToLower()) {
        { $_ -in @('quake','quake2','quake3','doom','idtech') } {
            return @{
                Include = '\.(c|cc|cpp|cxx|h|hh|hpp|inl|inc)$'
                Exclude = '[/\\](\.git|architecture|build|out|dist|obj|bin|Debug|Release|x64|Win32|\.vs|\.vscode|baseq2|baseq3|base)([/\\]|$)'
                Desc    = 'C game engine codebase (id Software / Quake-family)'
                Fence   = 'c'
            }
        }
        { $_ -in @('unreal','ue4','ue5') } {
            return @{
                Include = '\.(cpp|h|hpp|cc|cxx|inl|cs)$'
                Exclude = '[/\\](\.git|architecture|Binaries|Build|DerivedDataCache|Intermediate|Saved|\.vs|ThirdParty|GeneratedFiles|AutomationTool)([/\\]|$)'
                Desc    = 'Unreal Engine C++/C# source (Epic Games)'
                Fence   = 'cpp'
            }
        }
        'godot' {
            return @{
                Include = '\.(cpp|h|hpp|c|cc|gd|gdscript|tscn|tres|cs)$'
                Exclude = '[/\\](\.git|architecture|\.godot|\.import|build|export)([/\\]|$)'
                Desc    = 'Godot engine codebase (C++/GDScript/C#)'
                Fence   = 'cpp'
            }
        }
        'unity' {
            return @{
                Include = '\.(cs|shader|cginc|hlsl|compute|glsl|cpp|c|h)$'
                Exclude = '[/\\](\.git|architecture|Library|Temp|Obj|Build|Builds|Logs|UserSettings|\.vs)([/\\]|$)'
                Desc    = 'Unity game codebase (C#/shader)'
                Fence   = 'csharp'
            }
        }
        { $_ -in @('source','valve') } {
            return @{
                Include = '\.(cpp|h|hpp|c|cc|cxx|inl|inc|vpc|vgc)$'
                Exclude = '[/\\](\.git|architecture|build|out|obj|bin|Debug|Release|lib|thirdparty)([/\\]|$)'
                Desc    = 'Source Engine codebase (Valve / C++)'
                Fence   = 'cpp'
            }
        }
        'rust' {
            return @{
                Include = '\.(rs|toml)$'
                Exclude = '[/\\](\.git|architecture|target|\.cargo)([/\\]|$)'
                Desc    = 'Rust game engine codebase'
                Fence   = 'rust'
            }
        }
        { $_ -in @('generals','cnc','sage') } {
            return @{
                Include = '\.(cpp|h|hpp|c|cc|cxx|inl|inc)$'
                Exclude = '[/\\](\.git|architecture|Debug|Release|x64|Win32|\.vs|Run|place_steam_build_here)([/\\]|$)'
                Desc    = 'Command & Conquer Generals / Zero Hour (SAGE engine, EA/Westwood, C++)'
                Fence   = 'cpp'
            }
        }
        '' {
            return @{
                Include = '\.(c|cc|cpp|cxx|h|hh|hpp|inl|inc|cs|java|py|rs|lua|gd|gdscript|m|mm|swift)$'
                Exclude = '[/\\](\.git|architecture|build|out|dist|obj|bin|Debug|Release|\.vs|\.vscode|node_modules|\.godot|Library|Temp)([/\\]|$)'
                Desc    = 'game engine / game codebase'
                Fence   = 'c'
            }
        }
        default {
            Write-Host "Unknown preset: $name. Available: quake, doom, unreal, godot, unity, source, rust, generals" -ForegroundColor Red
            exit 2
        }
    }
}

# ---------------------------------------------------------------------------
# Get-FenceLang -- Map file extension to markdown fence language
# ---------------------------------------------------------------------------

function Get-FenceLang($file, $def) {
    $ext = [System.IO.Path]::GetExtension($file).TrimStart('.').ToLower()
    switch ($ext) {
        { $_ -in @('c','h','inc') }                             { return 'c' }
        { $_ -in @('cpp','cc','cxx','hpp','hh','hxx','inl') }   { return 'cpp' }
        'cs'     { return 'csharp' }
        'java'   { return 'java' }
        'py'     { return 'python' }
        'rs'     { return 'rust' }
        'lua'    { return 'lua' }
        { $_ -in @('gd','gdscript') }                           { return 'gdscript' }
        'swift'  { return 'swift' }
        { $_ -in @('m','mm') }                                  { return 'objectivec' }
        { $_ -in @('shader','cginc','hlsl','glsl','compute') }  { return 'hlsl' }
        'toml'   { return 'toml' }
        { $_ -in @('tscn','tres') }                             { return 'ini' }
        default  { return $def }
    }
}

# ---------------------------------------------------------------------------
# Trivial file detection
# ---------------------------------------------------------------------------

$script:trivialPatterns = @(
    '\.generated\.h$',
    '\.gen\.cpp$',
    '^Module\.[A-Za-z0-9_]+\.cpp$',
    'Classes\.h$'
)

function Test-TrivialFile($rel, $fullPath, $minLines) {
    $leaf = Split-Path $rel -Leaf
    foreach ($pat in $script:trivialPatterns) {
        if ($leaf -match $pat) { return $true }
    }
    $lines = @(Get-Content $fullPath -ErrorAction SilentlyContinue)
    if ($lines.Count -lt $minLines) { return $true }
    $nonInclude = $lines | Where-Object {
        $_.Trim() -ne '' -and
        $_ -notmatch '^\s*(#\s*(include|pragma|ifndef|define|endif)|//|/\*|\*/)'
    }
    if (@($nonInclude).Count -le 2) { return $true }
    return $false
}

function Write-TrivialStub($rel, $outPath) {
    $stub = "# $rel`n`n## Purpose`nAuto-generated or trivial file. No detailed analysis needed.`n`n## Responsibilities`n- Boilerplate / generated code`n"
    $stub | Set-Content -Path $outPath -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Get-OutputBudget -- Adaptive output token budget based on file size
# ---------------------------------------------------------------------------

function Get-OutputBudget($lineCount) {
    if ($lineCount -lt 50)  { return 300 }
    if ($lineCount -lt 200) { return 400 }
    if ($lineCount -lt 500) { return 600 }
    return 800
}

# ---------------------------------------------------------------------------
# Truncate-Source -- Cap source lines with head+tail truncation
# ---------------------------------------------------------------------------

function Truncate-Source($srcLines, $maxLines) {
    if ($maxLines -le 0 -or $srcLines.Count -le $maxLines) {
        return ($srcLines -join "`n")
    }
    $half = [int]($maxLines / 2)
    $head = $srcLines | Select-Object -First $half
    $tail = $srcLines | Select-Object -Last  $half
    $note = "/* ... TRUNCATED: showing first $half and last $half of $($srcLines.Count) lines ... */"
    return ($head -join "`n") + "`n`n$note`n`n" + ($tail -join "`n")
}

# ---------------------------------------------------------------------------
# Load-CompressedLSP -- Load LSP context, keeping only Symbol Overview section
# ---------------------------------------------------------------------------

function Load-CompressedLSP($serenaContextDir, $rel) {
    if (-not $serenaContextDir -or $serenaContextDir -eq '') { return '' }
    $ctxPath = Join-Path $serenaContextDir (($rel -replace '/','\') + '.serena_context.txt')
    if (-not (Test-Path $ctxPath)) { return '' }

    $content = Get-Content $ctxPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $content) { return '' }

    # Extract only Symbol Overview section (drop references, trimmed source to save tokens)
    $match = [regex]::Match($content, '(?s)(## Symbol Overview.*?)(?=\n## (?!Symbol)|$)')
    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }
    return ''
}

# ---------------------------------------------------------------------------
# Show-SimpleProgress -- Single-line progress display for synchronous loop
# ---------------------------------------------------------------------------

function Show-SimpleProgress($done, $total, $startTime) {
    $elapsed = ([datetime]::Now - $startTime).TotalSeconds
    $rate    = if ($elapsed -gt 0 -and $done -gt 0) { [math]::Round($done / $elapsed, 2) } else { 0 }
    $etaSec  = if ($rate -gt 0) { [math]::Round(($total - $done) / $rate) } else { 0 }
    if ($etaSec -gt 0) {
        $etaH = [int][math]::Floor($etaSec / 3600)
        $etaM = [int][math]::Floor(($etaSec % 3600) / 60)
        $etaS = [int]($etaSec % 60)
        $eta  = '{0}h{1:D2}m{2:D2}s' -f $etaH, $etaM, $etaS
    } else { $eta = '?' }
    $line = "PROGRESS: $done/$total  rate=${rate}/s  eta=$eta"
    [Console]::Write("`r" + $line.PadRight(80))
}
