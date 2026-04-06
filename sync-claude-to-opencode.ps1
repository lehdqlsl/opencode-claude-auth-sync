$ErrorActionPreference = "Stop"

$claudeCredsPath = if ($env:CLAUDE_CREDENTIALS_PATH) { $env:CLAUDE_CREDENTIALS_PATH } else { Join-Path $HOME ".claude\.credentials.json" }
$opencodeAuthPath = if ($env:OPENCODE_AUTH_PATH) { $env:OPENCODE_AUTH_PATH } else { Join-Path $HOME ".local\share\opencode\auth.json" }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$Version = "0.6.0"

$mode = "sync"
if ($args.Count -gt 0) {
    switch ($args[0]) {
        "--status" { $mode = "status" }
        "--help" { $mode = "help" }
        "-h" { $mode = "help" }
        "--version" { Write-Output "opencode-claude-auth-sync v$Version"; exit 0 }
        "-v" { Write-Output "opencode-claude-auth-sync v$Version"; exit 0 }
        default {
            Write-Error "Unknown command: $($args[0]). Run --help for usage."
            exit 1
        }
    }
}

if ($mode -eq "help") {
    @"
Usage: sync-claude-to-opencode.ps1 [command]

  (no args)           Sync Claude credentials to OpenCode
  --status            Show current token status and usage
  --help              Show this help
  --version           Show version
"@ | Write-Output
    exit 0
}

if (-not (Test-Path $opencodeAuthPath)) { exit 0 }

$deprecatedPlugin = Join-Path $env:LOCALAPPDATA "opencode\node_modules\opencode-anthropic-auth"
if (-not (Test-Path $deprecatedPlugin)) {
    $deprecatedPlugin = Join-Path $HOME ".cache\opencode\node_modules\opencode-anthropic-auth"
}
if (Test-Path $deprecatedPlugin) {
    Write-Warning "Deprecated opencode-anthropic-auth plugin detected in cache."
    Write-Warning "This may cause 429 errors. Remove it with:"
    Write-Warning "  Remove-Item -Recurse -Force '$deprecatedPlugin'"
}

function Read-ClaudeCreds {
    if (-not (Test-Path $claudeCredsPath)) { return $null }
    try {
        $raw = Get-Content $claudeCredsPath -Raw | ConvertFrom-Json
        return $(if ($raw.claudeAiOauth) { $raw.claudeAiOauth } else { $raw })
    } catch {
        Write-Error "Failed to parse Claude credentials: $_"
        exit 1
    }
}

function Invoke-CliRefresh {
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-Output "claude CLI not found, cannot auto-refresh"
        return $false
    }

    Write-Output "$(Get-Date -Format o) refreshing via claude CLI..."
    try {
        $proc = Start-Process -FilePath "claude" -ArgumentList "-p . --model claude-haiku-4-5" -NoNewWindow -PassThru -RedirectStandardOutput "NUL" -RedirectStandardError "NUL"
        $proc | Wait-Process -Timeout 60 -ErrorAction SilentlyContinue
        if (-not $proc.HasExited) {
            $proc | Stop-Process -Force
        }
    } catch {}
    return $true
}

function Get-TokenStatus {
    param($Creds)

    $nowMs = [long]([datetime]::UtcNow - [datetime]::new(1970, 1, 1)).TotalMilliseconds
    $remaining = [long]$Creds.expiresAt - $nowMs
    $hours = [math]::Floor($remaining / 3600000)
    $mins = [math]::Floor(($remaining % 3600000) / 60000)
    [PSCustomObject]@{
        Remaining = $remaining
        Display = if ($remaining -gt 0) { "${hours}h ${mins}m remaining" } else { "EXPIRED" }
        Expires = [datetime]::new(1970, 1, 1).AddMilliseconds([double]$Creds.expiresAt).ToString("o")
    }
}

function Show-UsageStatus {
    param($AccessToken)

    if (-not $AccessToken) { return }

    try {
        $usage = Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/usage" -Headers @{
            Authorization = "Bearer $AccessToken"
            "anthropic-beta" = "oauth-2025-04-20"
        }
    } catch {
        return
    }

    $formatReset = {
        param($Value)
        if (-not $Value) { return "?" }
        try { return ([datetime]$Value).ToUniversalTime().ToString("o") } catch { return [string]$Value }
    }

    $formatUtil = {
        param($Value)
        if ($null -eq $Value) { return "?" }
        return [string]$Value
    }

    Write-Output "Usage:   5h $(& $formatUtil $usage.five_hour.utilization)% (reset: $(& $formatReset $usage.five_hour.resets_at))"
    Write-Output "         7d $(& $formatUtil $usage.seven_day.utilization)% (reset: $(& $formatReset $usage.seven_day.resets_at))"
    if ($null -ne $usage.seven_day_sonnet -and $null -ne $usage.seven_day_sonnet.utilization) {
        Write-Output "         sonnet $(& $formatUtil $usage.seven_day_sonnet.utilization)%"
    }
}

function Write-JsonAtomic {
    param(
        [string]$Path,
        [object]$Value
    )

    $tmpPath = "$Path.tmp.$PID"
    $json = $Value | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($tmpPath, $json, $utf8NoBom)
    Move-Item -Path $tmpPath -Destination $Path -Force
}

function Show-Status {
    $creds = Read-ClaudeCreds
    if (-not $creds) {
        Write-Output "No Claude credentials found"
        exit 0
    }

    $status = Get-TokenStatus $creds
    if ($status.Remaining -le 0) {
        Write-Output "Status:  EXPIRED"
        Write-Output "Expired: $($status.Expires)"
    } else {
        Write-Output "Status:  valid ($($status.Display))"
        Write-Output "Expires: $($status.Expires)"
    }
    if ($creds.subscriptionType) {
        $tier = if ($creds.rateLimitTier) { " ($($creds.rateLimitTier))" } else { "" }
        Write-Output "Plan:    $($creds.subscriptionType)$tier"
    }
    Show-UsageStatus $creds.accessToken
}

function Write-OpenCodeAuth {
    param($Creds)

    if (-not $Creds -or -not $Creds.accessToken -or -not $Creds.refreshToken -or -not $Creds.expiresAt) {
        throw "Credentials incomplete"
    }

    try {
        $auth = Get-Content $opencodeAuthPath -Raw | ConvertFrom-Json
    } catch {
        Write-Error "Failed to parse ${opencodeAuthPath}: $_"
        exit 1
    }

    $status = Get-TokenStatus $Creds
    if ($auth.anthropic -and
        $auth.anthropic.access -eq $Creds.accessToken -and
        $auth.anthropic.refresh -eq $Creds.refreshToken -and
        $auth.anthropic.expires -eq $Creds.expiresAt) {
        Write-Output "$(Get-Date -Format o) already in sync ($($status.Display))"
        return
    }

    if (-not $auth.anthropic) {
        $auth | Add-Member -NotePropertyName "anthropic" -NotePropertyValue ([PSCustomObject]@{}) -Force
    }

    $auth.anthropic = [PSCustomObject]@{
        type = "oauth"
        access = $Creds.accessToken
        refresh = $Creds.refreshToken
        expires = $Creds.expiresAt
    }

    Write-JsonAtomic -Path $opencodeAuthPath -Value $auth
    Write-Output "$(Get-Date -Format o) synced ($($status.Display))"
}

function Do-Sync {
    $creds = Read-ClaudeCreds
    if (-not $creds) {
        Write-Output "No credentials available"
        exit 0
    }

    $status = Get-TokenStatus $creds
    if ($status.Remaining -le 0) {
        Invoke-CliRefresh | Out-Null
        $fresh = Read-ClaudeCreds
        if (-not $fresh -or -not $fresh.accessToken) {
            Write-Error "No Claude credentials found after refresh"
            exit 1
        }
        $creds = $fresh
    }

    Write-OpenCodeAuth $creds
}

switch ($mode) {
    "status" { Show-Status; break }
    default { Do-Sync }
}
