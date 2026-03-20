$ErrorActionPreference = "Stop"

$claudeCredsPath = if ($env:CLAUDE_CREDENTIALS_PATH) { $env:CLAUDE_CREDENTIALS_PATH } else { Join-Path $HOME ".claude\.credentials.json" }
$opencodeAuthPath = if ($env:OPENCODE_AUTH_PATH) { $env:OPENCODE_AUTH_PATH } else { Join-Path $HOME ".local\share\opencode\auth.json" }
$refreshThreshold = 900000 # 15 minutes

if (-not (Test-Path $opencodeAuthPath)) { exit 0 }

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

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
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { return }
    Write-Output "$(Get-Date -Format o) token expiring soon, refreshing via claude CLI..."
    try {
        $proc = Start-Process -FilePath "claude" -ArgumentList "-p . --model claude-haiku-4-5-20250514" -NoNewWindow -PassThru -RedirectStandardOutput "NUL" -RedirectStandardError "NUL"
        $proc | Wait-Process -Timeout 60 -ErrorAction SilentlyContinue
        if (-not $proc.HasExited) { $proc | Stop-Process -Force }
    } catch {}
}

$creds = Read-ClaudeCreds

if (-not $creds) {
    Write-Output "No Claude credentials found"
    exit 0
}

if (-not $creds.accessToken -or -not $creds.refreshToken -or -not $creds.expiresAt) {
    Write-Error "Claude credentials incomplete"
    exit 1
}

$nowMs = [long]([datetime]::UtcNow - [datetime]::new(1970, 1, 1)).TotalMilliseconds
$remaining = $creds.expiresAt - $nowMs

if ($remaining -le $refreshThreshold) {
    Invoke-CliRefresh
    $creds = Read-ClaudeCreds
    if (-not $creds -or -not $creds.accessToken) {
        Write-Error "No Claude credentials found after refresh"
        exit 1
    }
    $remaining = $creds.expiresAt - [long]([datetime]::UtcNow - [datetime]::new(1970, 1, 1)).TotalMilliseconds
}

$hours = [math]::Floor($remaining / 3600000)
$mins = [math]::Floor(($remaining % 3600000) / 60000)
$status = if ($remaining -gt 0) { "${hours}h ${mins}m remaining" } else { "EXPIRED" }

try {
    $auth = Get-Content $opencodeAuthPath -Raw | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse ${opencodeAuthPath}: $_"
    exit 1
}

if ($auth.anthropic -and
    $auth.anthropic.access -eq $creds.accessToken -and
    $auth.anthropic.refresh -eq $creds.refreshToken -and
    $auth.anthropic.expires -eq $creds.expiresAt) {
    Write-Output "$(Get-Date -Format o) already in sync ($status)"
    exit 0
}

if (-not $auth.anthropic) {
    $auth | Add-Member -NotePropertyName "anthropic" -NotePropertyValue ([PSCustomObject]@{}) -Force
}

$auth.anthropic = [PSCustomObject]@{
    type    = "oauth"
    access  = $creds.accessToken
    refresh = $creds.refreshToken
    expires = $creds.expiresAt
}

$tmpPath = "$opencodeAuthPath.tmp.$PID"
try {
    $json = $auth | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($tmpPath, $json, $utf8NoBom)
    Move-Item -Path $tmpPath -Destination $opencodeAuthPath -Force
} catch {
    if (Test-Path $tmpPath) { Remove-Item $tmpPath -ErrorAction SilentlyContinue }
    throw
}
Write-Output "$(Get-Date -Format o) synced ($status)"
