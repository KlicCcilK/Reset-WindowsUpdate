<#
.SYNOPSIS
    Resets Windows Update components by stopping related services, renaming
    SoftwareDistribution and catroot2, then restarting the services.

.DESCRIPTION
    Designed for cases where Windows Update hangs on "Working on updates..."
    or reports 0x80240007 (WU_E_INVALIDINDEX) due to a corrupted download
    datastore or catalog cache.

    Features:
    - Confirms each service is stopped
    - Retries failed stops
    - Force-stops stubborn services (common with cryptsvc)
    - Minimal console output by default; detailed output with -Verbose / -v
    - Prompts to reboot at the end

.PARAMETER Verbose
    Alias: -v
    Shows detailed progress (service states, retry attempts, etc.)

.EXAMPLE
    .\Reset-WindowsUpdateComponents.ps1

.EXAMPLE
    .\Reset-WindowsUpdateComponents.ps1 -Verbose
    .\Reset-WindowsUpdateComponents.ps1 -v
#>

[CmdletBinding()]
param(
    [Alias('v')]
    [switch]$Verbose
)

# Enable Write-Verbose when -v / -Verbose is passed
if ($Verbose) {
    $VerbosePreference = 'Continue'
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$services = @(
    'bits',          # Background Intelligent Transfer Service
    'wuauserv',      # Windows Update
    'cryptsvc',      # Cryptographic Services (often stubborn)
    'msiserver'      # Windows Installer
)

$foldersToRename = @(
    @{ Path = "$env:SystemRoot\SoftwareDistribution"; NewName = 'SoftwareDistribution.bak' },
    @{ Path = "$env:SystemRoot\System32\catroot2";    NewName = 'catroot2.bak' }
)

$maxRetries = 3
$retryDelaySeconds = 2

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
function Write-Status {
    param([string]$Message, [string]$Color = 'White')
    Write-Host $Message -ForegroundColor $Color
}

function Get-ServiceState {
    param([string]$Name)
    try {
        return (Get-Service -Name $Name -ErrorAction Stop).Status
    }
    catch {
        return 'NotFound'
    }
}

function Stop-ServiceRobust {
    param(
        [string]$Name,
        [int]$MaxAttempts = $maxRetries
    )

    $state = Get-ServiceState -Name $Name
    if ($state -eq 'NotFound') {
        Write-Status "  [SKIP] Service '$Name' not found." -Color DarkGray
        return $true
    }
    if ($state -eq 'Stopped') {
        Write-Status "  [OK]   $Name is already stopped." -Color Green
        Write-Verbose "Service $Name was already in Stopped state."
        return $true
    }

    Write-Status "  Stopping $Name (current state: $state)..." -Color Yellow
    Write-Verbose "Attempting graceful stop of $Name..."

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Stop-Service -Name $Name -ErrorAction Stop -Force:$false
            Start-Sleep -Seconds $retryDelaySeconds
            $state = Get-ServiceState -Name $Name
            if ($state -eq 'Stopped') {
                Write-Status "  [OK]   $Name stopped (attempt $attempt)." -Color Green
                Write-Verbose "$Name successfully stopped on attempt $attempt."
                return $true
            }
            Write-Verbose "$Name still $state after attempt $attempt."
        }
        catch {
            Write-Verbose "Graceful stop attempt $attempt for $Name failed: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $retryDelaySeconds
    }

    # Force stop if still running
    Write-Status "  [WARN] $Name did not stop gracefully. Forcing stop..." -Color DarkYellow
    Write-Verbose "Issuing Force stop for $Name."
    try {
        Stop-Service -Name $Name -Force -ErrorAction Stop
        Start-Sleep -Seconds $retryDelaySeconds
        $state = Get-ServiceState -Name $Name
        if ($state -eq 'Stopped') {
            Write-Status "  [OK]   $Name force-stopped." -Color Green
            Write-Verbose "$Name was force-stopped successfully."
            return $true
        }
        else {
            Write-Status "  [FAIL] $Name is still $state after force-stop." -Color Red
            Write-Verbose "$Name remains in state $state after force-stop."
            return $false
        }
    }
    catch {
        Write-Status "  [FAIL] Could not force-stop $Name : $($_.Exception.Message)" -Color Red
        Write-Verbose "Force-stop exception for $Name : $($_.Exception.Message)"
        return $false
    }
}

function Rename-FolderRobust {
    param(
        [string]$Path,
        [string]$NewName
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Status "  [SKIP] Folder does not exist: $Path" -Color DarkGray
        Write-Verbose "Path not found, skipping rename: $Path"
        return $true
    }

    $dest = Join-Path (Split-Path $Path) $NewName
    if (Test-Path -LiteralPath $dest) {
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $NewName = "$NewName.$timestamp"
        $dest = Join-Path (Split-Path $Path) $NewName
        Write-Verbose "Destination already exists. Using timestamped name: $NewName"
    }

    Write-Status "  Renaming $Path -> $NewName" -Color Cyan
    Write-Verbose "Rename-Item -Path '$Path' -NewName '$NewName'"

    try {
        Rename-Item -LiteralPath $Path -NewName $NewName -Force -ErrorAction Stop
        Write-Status "  [OK]   Renamed successfully." -Color Green
        return $true
    }
    catch {
        Write-Status "  [WARN] Rename failed: $($_.Exception.Message)" -Color DarkYellow
        Write-Verbose "Initial rename failed. Attempting takeown + icacls..."

        # Fallback: take ownership and grant full control, then retry
        try {
            & takeown.exe /f $Path /r /d y 2>&1 | Out-Null
            & icacls.exe $Path /grant "Administrators:F" /t /c 2>&1 | Out-Null
            Start-Sleep -Seconds 1
            Rename-Item -LiteralPath $Path -NewName $NewName -Force -ErrorAction Stop
            Write-Status "  [OK]   Renamed after taking ownership." -Color Green
            return $true
        }
        catch {
            Write-Status "  [FAIL] Could not rename $Path even after takeown." -Color Red
            Write-Verbose "Final rename failure: $($_.Exception.Message)"
            return $false
        }
    }
}

function Start-ServiceSafe {
    param([string]$Name)

    $state = Get-ServiceState -Name $Name
    if ($state -eq 'NotFound') {
        Write-Status "  [SKIP] Service '$Name' not found." -Color DarkGray
        return
    }
    if ($state -eq 'Running') {
        Write-Status "  [OK]   $Name is already running." -Color Green
        return
    }

    Write-Status "  Starting $Name..." -Color Cyan
    try {
        Start-Service -Name $Name -ErrorAction Stop
        Start-Sleep -Seconds 1
        $state = Get-ServiceState -Name $Name
        if ($state -eq 'Running') {
            Write-Status "  [OK]   $Name started." -Color Green
        }
        else {
            Write-Status "  [WARN] $Name is in state: $state" -Color DarkYellow
        }
    }
    catch {
        Write-Status "  [FAIL] Could not start $Name : $($_.Exception.Message)" -Color Red
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Status "`n=== Windows Update Component Reset ===" -Color Cyan
Write-Status "Minimal output mode. Use -Verbose or -v for details.`n" -Color DarkGray

# --- Phase 1: Stop services (with retry pass) ---
Write-Status "Phase 1: Stopping services..." -Color White
$failedStops = @()

foreach ($svc in $services) {
    $success = Stop-ServiceRobust -Name $svc
    if (-not $success) {
        $failedStops += $svc
    }
}

# Second pass for anything that failed
if ($failedStops.Count -gt 0) {
    Write-Status "`nRetrying services that failed to stop: $($failedStops -join ', ')" -Color DarkYellow
    Write-Verbose "Second-pass retry for: $($failedStops -join ', ')"
    $stillFailed = @()
    foreach ($svc in $failedStops) {
        $success = Stop-ServiceRobust -Name $svc -MaxAttempts 2
        if (-not $success) {
            $stillFailed += $svc
        }
    }
    if ($stillFailed.Count -gt 0) {
        Write-Status "Warning: The following services could not be stopped: $($stillFailed -join ', ')" -Color Red
        Write-Status "Continuing anyway (rename may still fail for catroot2 if cryptsvc is locked)." -Color DarkYellow
    }
}

# --- Phase 2: Rename folders ---
Write-Status "`nPhase 2: Renaming folders..." -Color White
$renameFailures = @()

foreach ($folder in $foldersToRename) {
    $ok = Rename-FolderRobust -Path $folder.Path -NewName $folder.NewName
    if (-not $ok) {
        $renameFailures += $folder.Path
    }
}

# --- Phase 3: Start services ---
Write-Status "`nPhase 3: Starting services..." -Color White
foreach ($svc in $services) {
    Start-ServiceSafe -Name $svc
}

# --- Summary ---
Write-Status "`n=== Summary ===" -Color Cyan
if ($renameFailures.Count -eq 0) {
    Write-Status "All target folders were renamed (or did not exist)." -Color Green
}
else {
    Write-Status "Some folders could not be renamed:" -Color Yellow
    $renameFailures | ForEach-Object { Write-Status "  - $_" -Color Yellow }
    Write-Status "Windows Update may still work if SoftwareDistribution was renamed." -Color DarkGray
}

Write-Status "`nA reboot is strongly recommended so the new folders are fully initialized." -Color Yellow

# --- Reboot prompt ---
$reboot = Read-Host "`nReboot now? (Y/N)"
if ($reboot -match '^[Yy]') {
    Write-Status "Rebooting in 5 seconds..." -Color Cyan
    Start-Sleep -Seconds 5
    Restart-Computer -Force
}
else {
    Write-Status "Reboot skipped. Please reboot manually when convenient." -Color DarkGray
}

Write-Status "`nDone." -Color Green
