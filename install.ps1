$ErrorActionPreference = "Stop"

$installDir = Join-Path $HOME ".local\bin"
$scriptName = "sync-claude-to-opencode.ps1"
$repoRaw = "https://raw.githubusercontent.com/lehdqlsl/opencode-claude-auth-sync/main"

$claudeCreds = Join-Path $HOME ".claude\.credentials.json"
$opencodeAuth = Join-Path $HOME ".local\share\opencode\auth.json"

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

Write-Output "==> Checking prerequisites..."

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Error "ERROR: node is required but not found"; exit 1
}
if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
    Write-Error "ERROR: opencode is required but not found"; exit 1
}
if (-not (Test-Path $claudeCreds)) {
    Write-Error "ERROR: Claude credentials not found at $claudeCreds`nRun 'claude' first to authenticate."
    exit 1
}
if (-not (Test-Path $opencodeAuth)) {
    Write-Error "ERROR: OpenCode auth file not found at $opencodeAuth`nRun 'opencode' at least once first."
    exit 1
}

Write-Output "==> Installing sync script to $installDir\$scriptName..."
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
Invoke-WebRequest -Uri "$repoRaw/$scriptName" -OutFile "$installDir\$scriptName"

Write-Output "==> Running initial sync..."
# Prefer pwsh (PS 7+) over powershell.exe (5.1) for UTF-8 correctness
$psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell.exe" }
& $psExe -ExecutionPolicy Bypass -File "$installDir\$scriptName"
if ($LASTEXITCODE -eq 0) {
    Write-Output "    Initial sync complete."
} else {
    Write-Warning "    Initial sync failed (exit code $LASTEXITCODE)."
}

Write-Output "==> Checking opencode-claude-auth in opencode.json..."
$opencodeConfig = Join-Path $HOME ".config\opencode\opencode.json"
if ((Test-Path $opencodeConfig) -and (Select-String -Path $opencodeConfig -Pattern "opencode-claude-auth" -Quiet)) {
    Write-Output "    WARNING: 'opencode-claude-auth' found in $opencodeConfig"
    Write-Output "    This package is incompatible. Please remove it manually from the 'plugin' array."
}

$noScheduler = $args -contains "--no-scheduler"

if ($noScheduler) {
    Write-Output "==> Skipping scheduler setup (--no-scheduler)."
    Write-Output "    Run manually when needed: $installDir\$scriptName"
} else {
    Write-Output "==> Setting up Task Scheduler (every 15 minutes)..."
    $taskName = "SyncClaudeToOpenCode"
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

    if ($existingTask) {
        Write-Output "    Task already registered. Skipping."
    } else {
        $action = New-ScheduledTaskAction -Execute $psExe -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installDir\$scriptName`""
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15)
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description "Sync Claude CLI credentials to OpenCode" | Out-Null
        Write-Output "    Task Scheduler registered."
    }
}

Write-Output ""
Write-Output "Done! Verify with:"
Write-Output "  opencode providers list    # Should show: Anthropic oauth"
Write-Output "  opencode models anthropic  # Should list Claude models"
