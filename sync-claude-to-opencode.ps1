$ErrorActionPreference = "Stop"

$claudeCredsPath = if ($env:CLAUDE_CREDENTIALS_PATH) { $env:CLAUDE_CREDENTIALS_PATH } else { Join-Path $HOME ".claude\.credentials.json" }
$opencodeAuthPath = if ($env:OPENCODE_AUTH_PATH) { $env:OPENCODE_AUTH_PATH } else { Join-Path $HOME ".local\share\opencode\auth.json" }
$accountsDir = Join-Path $HOME ".config\opencode-claude-auth-sync"
$accountsFile = Join-Path $accountsDir "accounts.json"
$accountsLockDir = Join-Path $accountsDir "accounts.lock"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$mode = "sync"
$label = $null
if ($args.Count -gt 0) {
    switch ($args[0]) {
        "--status" { $mode = "status" }
        "--force" { $mode = "force" }
        "--add" { $mode = "add"; if ($args.Count -gt 1) { $label = $args[1] } }
        "--login" { $mode = "login"; if ($args.Count -gt 1) { $label = $args[1] } }
        "--remove" { $mode = "remove"; if ($args.Count -gt 1) { $label = $args[1] } }
        "--list" { $mode = "list" }
        "--switch" { $mode = "switch"; if ($args.Count -gt 1) { $label = $args[1] } }
        "--rotate" { $mode = "rotate" }
        "--help" { $mode = "help" }
        "-h" { $mode = "help" }
    }
}

if ($mode -eq "help") {
    @"
Usage: sync-claude-to-opencode.ps1 [command]

Sync:
  (no args)           Sync active account to OpenCode
  --status            Show current token status
  --force             Force refresh via Claude CLI

Multi-account:
  --add <label>       Save current Claude CLI credentials as named account
  --login <label>     Log into Claude CLI, then save it as named account
  --remove <label>    Remove a stored account
  --list              List all stored accounts with status
  --switch <label>    Switch active account and sync
  --rotate            Rotate to next account (round-robin) and sync

  --help              Show this help
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

function Ensure-AccountsDir {
    New-Item -ItemType Directory -Force -Path $accountsDir | Out-Null
}

function Acquire-AccountsLock {
    Ensure-AccountsDir
    for ($i = 0; $i -lt 300; $i++) {
        try {
            [System.IO.Directory]::CreateDirectory($accountsLockDir) | Out-Null
            return
        } catch {
            Start-Sleep -Milliseconds 100
        }
    }
    throw "Timed out waiting for accounts lock"
}

function Release-AccountsLock {
    if (Test-Path $accountsLockDir) {
        Remove-Item $accountsLockDir -Force -ErrorAction SilentlyContinue
    }
}

function Has-Accounts {
    Test-Path $accountsFile
}

function Read-AccountsStore {
    if (-not (Has-Accounts)) {
        return @{
            accounts = @{}
            active = $null
            rotationIndex = 0
        }
    }

    $raw = Get-Content $accountsFile -Raw | ConvertFrom-Json -AsHashtable
    if (-not $raw.ContainsKey("accounts") -or -not $raw.accounts) {
        $raw.accounts = @{}
    }
    if (-not $raw.ContainsKey("rotationIndex")) {
        $raw.rotationIndex = 0
    }
    return $raw
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

function Get-ActiveCreds {
    if (Has-Accounts) {
        $store = Read-AccountsStore
        if (-not $store.active -or -not $store.accounts.ContainsKey($store.active)) {
            return $null
        }
        $acc = $store.accounts[$store.active]
        return [PSCustomObject]@{
            accessToken = $acc.accessToken
            refreshToken = $acc.refreshToken
            expiresAt = $acc.expiresAt
            subscriptionType = $acc.subscriptionType
            rateLimitTier = $acc.rateLimitTier
        }
    }

    return Read-ClaudeCreds
}

function Update-AccountInStore {
    param($Creds)

    if (-not (Has-Accounts)) { return }

    Acquire-AccountsLock
    try {
        $store = Read-AccountsStore
        if (-not $store.active -or -not $store.accounts.ContainsKey($store.active)) { return }
        $acc = $store.accounts[$store.active]
        $acc.accessToken = $Creds.accessToken
        $acc.refreshToken = $Creds.refreshToken
        $acc.expiresAt = $Creds.expiresAt
        if ($Creds.subscriptionType) { $acc.subscriptionType = $Creds.subscriptionType }
        if ($Creds.rateLimitTier) { $acc.rateLimitTier = $Creds.rateLimitTier }
        Write-JsonAtomic -Path $accountsFile -Value $store
    } finally {
        Release-AccountsLock
    }
}

function Auto-RotateToValid {
    if (-not (Has-Accounts)) { return $false }

    Acquire-AccountsLock
    try {
        $store = Read-AccountsStore
        $labels = @($store.accounts.Keys)
        if ($labels.Count -eq 0) { return $false }

        $nowMs = [long]([datetime]::UtcNow - [datetime]::new(1970, 1, 1)).TotalMilliseconds
        $start = (([int]$store.rotationIndex) + 1) % $labels.Count

        for ($i = 0; $i -lt $labels.Count; $i++) {
            $idx = ($start + $i) % $labels.Count
            $candidate = $labels[$idx]
            $acc = $store.accounts[$candidate]
            if ([long]$acc.expiresAt -gt $nowMs) {
                $store.active = $candidate
                $store.rotationIndex = $idx
                Write-JsonAtomic -Path $accountsFile -Value $store
                Write-Output "$(Get-Date -Format o) auto-rotated to: $candidate"
                return $true
            }
        }

        return $false
    } finally {
        Release-AccountsLock
    }
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
    $creds = Get-ActiveCreds
    if (-not $creds) {
        Write-Output "No credentials available"
        exit 0
    }

    $status = Get-TokenStatus $creds
    if ($status.Remaining -le 0) {
        if (Has-Accounts -and (Auto-RotateToValid)) {
            $creds = Get-ActiveCreds
        } else {
            Invoke-CliRefresh | Out-Null
            $fresh = Read-ClaudeCreds
            if (-not $fresh -or -not $fresh.accessToken) {
                Write-Error "No Claude credentials found after refresh"
                exit 1
            }
            Update-AccountInStore $fresh
            $creds = Get-ActiveCreds
            if (-not $creds) { $creds = $fresh }
        }
    }

    Write-OpenCodeAuth $creds
}

function Show-Status {
    if (Has-Accounts) {
        $store = Read-AccountsStore
        if (-not $store.active -or -not $store.accounts.ContainsKey($store.active)) {
            Write-Output "No active account"
            exit 1
        }
        $acc = $store.accounts[$store.active]
        $status = Get-TokenStatus $acc
        $count = @($store.accounts.Keys).Count
        Write-Output "Account: $($store.active) ($count total)"
        if ($status.Remaining -le 0) {
            Write-Output "Status:  EXPIRED"
            Write-Output "Expired: $($status.Expires)"
        } else {
            Write-Output "Status:  valid ($($status.Display))"
            Write-Output "Expires: $($status.Expires)"
        }
        if ($acc.subscriptionType) {
            Write-Output "Plan:    $($acc.subscriptionType)"
        }
        Show-UsageStatus $acc.accessToken
        return
    }

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
    Show-UsageStatus $creds.accessToken
}

function Add-Account {
    param([string]$Label)

    if (-not $Label) {
        Write-Error "Usage: --add <label>"
        exit 1
    }

    $creds = Read-ClaudeCreds
    if (-not $creds) {
        Write-Error "No Claude credentials found. Run 'claude' first to authenticate."
        exit 1
    }
    if (-not $creds.accessToken -or -not $creds.refreshToken -or -not $creds.expiresAt) {
        Write-Error "Claude credentials incomplete"
        exit 1
    }

    Acquire-AccountsLock
    try {
        $store = Read-AccountsStore
        $isUpdate = $store.accounts.ContainsKey($Label)
        $store.accounts[$Label] = @{
            accessToken = $creds.accessToken
            refreshToken = $creds.refreshToken
            expiresAt = $creds.expiresAt
            subscriptionType = $creds.subscriptionType
            rateLimitTier = $creds.rateLimitTier
            addedAt = (Get-Date).ToUniversalTime().ToString("o")
        }
        if (-not $store.active -or -not $store.accounts.ContainsKey($store.active)) {
            $store.active = $Label
        }
        Write-JsonAtomic -Path $accountsFile -Value $store
        $status = Get-TokenStatus $creds
        $verb = if ($isUpdate) { "Updated" } else { "Added" }
        $activeTag = if ($store.active -eq $Label) { " (active)" } else { "" }
        $count = @($store.accounts.Keys).Count
        Write-Output "$verb`: $Label$activeTag — $($status.Display)"
        Write-Output "$count account(s) total."
    } finally {
        Release-AccountsLock
    }
}

function Remove-Account {
    param([string]$Label)

    if (-not $Label) {
        Write-Error "Usage: --remove <label>"
        exit 1
    }
    if (-not (Has-Accounts)) {
        Write-Error "No accounts stored."
        exit 1
    }

    Acquire-AccountsLock
    try {
        $store = Read-AccountsStore
        if (-not $store.accounts.ContainsKey($Label)) {
            Write-Error "Account not found: $Label"
            exit 1
        }

        $count = @($store.accounts.Keys).Count
        if ($store.active -eq $Label -and $count -gt 1) {
            $next = @($store.accounts.Keys | Where-Object { $_ -ne $Label })[0]
            $store.active = $next
            $store.rotationIndex = 0
            Write-Output "Active switched to: $next"
        } elseif ($count -eq 1) {
            $store.active = $null
            $store.rotationIndex = 0
        }

        $store.accounts.Remove($Label)
        Write-JsonAtomic -Path $accountsFile -Value $store
        Write-Output "Removed: $Label. $(@($store.accounts.Keys).Count) account(s) remaining."
    } finally {
        Release-AccountsLock
    }
}

function List-Accounts {
    if (-not (Has-Accounts)) {
        Write-Output "No accounts stored. Use --add <label> to add one."
        exit 0
    }

    $store = Read-AccountsStore
    $labels = @($store.accounts.Keys)
    if ($labels.Count -eq 0) {
        Write-Output "No accounts stored."
        exit 0
    }

    Write-Output ""
    Write-Output "  Label            Status     Remaining    Subscription"
    Write-Output "  ---------------  ---------  -----------  ------------"
    foreach ($name in $labels) {
        $acc = $store.accounts[$name]
        $status = Get-TokenStatus $acc
        $marker = if ($store.active -eq $name) { " *" } else { "" }
        $state = if ($status.Remaining -gt 0) { "valid" } else { "EXPIRED" }
        $remaining = if ($status.Remaining -gt 0) { $status.Display.Replace(" remaining", "") } else { "-" }
        $sub = if ($acc.subscriptionType) { $acc.subscriptionType } else { "-" }
        Write-Output (("  {0,-17}{1,-11}{2,-13}{3}" -f ($name + $marker), $state, $remaining, $sub))
    }
    Write-Output ""
    Write-Output "  * = active"
    Write-Output ""
}

function Switch-Account {
    param([string]$Label)

    if (-not $Label) {
        Write-Error "Usage: --switch <label>"
        exit 1
    }
    if (-not (Has-Accounts)) {
        Write-Error "No accounts stored."
        exit 1
    }

    Acquire-AccountsLock
    try {
        $store = Read-AccountsStore
        if (-not $store.accounts.ContainsKey($Label)) {
            Write-Error "Account not found: $Label"
            exit 1
        }
        if ($store.active -eq $Label) {
            Write-Output "Already active: $Label"
        } else {
            $labels = @($store.accounts.Keys)
            $store.active = $Label
            $store.rotationIndex = [array]::IndexOf($labels, $Label)
            Write-JsonAtomic -Path $accountsFile -Value $store
            Write-Output "Switched to: $Label"
        }
    } finally {
        Release-AccountsLock
    }

    Do-Sync
}

function Rotate-Account {
    if (-not (Has-Accounts)) {
        Write-Error "No accounts stored."
        exit 1
    }

    Acquire-AccountsLock
    try {
        $store = Read-AccountsStore
        $labels = @($store.accounts.Keys)
        if ($labels.Count -lt 2) {
            Write-Error "Need at least 2 accounts to rotate. Have: $($labels.Count)"
            exit 1
        }
        $nextIndex = (([int]$store.rotationIndex) + 1) % $labels.Count
        $store.rotationIndex = $nextIndex
        $store.active = $labels[$nextIndex]
        Write-JsonAtomic -Path $accountsFile -Value $store
        Write-Output "Rotated to: $($store.active) ($($nextIndex + 1)/$($labels.Count))"
    } finally {
        Release-AccountsLock
    }

    Do-Sync
}

function Login-Account {
    param([string]$Label)

    if (-not $Label) {
        Write-Error "Usage: --login <label>"
        exit 1
    }
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-Error "claude CLI not found"
        exit 1
    }

    claude auth logout 2>$null
    Write-Output "==> Log in with the account you want to save as '$Label'"
    claude auth login --claudeai
    Add-Account $Label
}

switch ($mode) {
    "add" { Add-Account $label; break }
    "login" { Login-Account $label; break }
    "remove" { Remove-Account $label; break }
    "list" { List-Accounts; break }
    "switch" { Switch-Account $label; break }
    "rotate" { Rotate-Account; break }
    "status" { Show-Status; break }
    "force" {
        Invoke-CliRefresh | Out-Null
        $fresh = Read-ClaudeCreds
        if ($fresh) {
            Update-AccountInStore $fresh
        }
        Do-Sync
        break
    }
    default { Do-Sync }
}
