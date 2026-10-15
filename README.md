# Reset-WindowsUpdateComponents.ps1

## Description

A robust PowerShell utility that resets the core Windows Update working directories (`SoftwareDistribution` and `catroot2`) to recover from stuck or failed update scenarios.

It is designed for cases where Windows Update hangs on “Working on updates…”, updates remain stuck on “Pending download”, or the Windows Update Agent logs repeated `0x80240007` (`WU_E_INVALIDINDEX`) errors caused by a corrupted or inconsistent download datastore / catalog cache.

The script:
- Stops the services that lock the folders (`bits`, `wuauserv`, `cryptsvc`, `msiserver`)
- Confirms each service has actually stopped
- Retries failed stops and force-stops stubborn services (especially `cryptsvc`)
- Renames the two folders so Windows rebuilds clean copies
- Restarts the services
- Prompts for a reboot

## When to Use

Use this script when you see symptoms such as:

- Windows Update UI stuck on “Working on updates…” for a long time
- All updates showing as “Pending download” with the Download & install button grayed out
- Event Viewer / `WindowsUpdate.log` showing repeated `0x80240007` failures in `HandlerDownloadRequestMap` or `downloadmanager`
- Standard “Check for updates” does nothing or immediately returns to the same stuck state
- The problem appeared on one machine after a clean image (i.e., not an image-wide issue)

It is a first-line recovery step. It does **not** remove installed updates or change Windows Update policies.

## Requirements

- Windows 10 / 11 (or Windows Server with the Desktop Experience)
- Elevated PowerShell session (Run as Administrator)
- PowerShell 5.1 or later

## Usage

```powershell
# Default (minimal output)
.\Reset-WindowsUpdateComponents.ps1

# Verbose / detailed output
.\Reset-WindowsUpdateComponents.ps1 -Verbose
# or the short alias
.\Reset-WindowsUpdateComponents.ps1 -v
```

### Parameters

| Parameter   | Alias | Description                                      |
|-------------|-------|--------------------------------------------------|
| `-Verbose`  | `-v`  | Enables detailed `Write-Verbose` progress output |

No other parameters are required.

## What the Script Does

1. **Stop phase**  
   Attempts to stop `bits`, `wuauserv`, `cryptsvc`, and `msiserver`.  
   For each service it verifies the stopped state, retries, and falls back to a force-stop if needed.  
   Any services that still fail are retried in a second pass.

2. **Rename phase**  
   Renames:
   - `C:\Windows\SoftwareDistribution` → `SoftwareDistribution.bak`
   - `C:\Windows\System32\catroot2` → `catroot2.bak`  

   If a `.bak` already exists, a timestamp is appended.  
   If a rename is denied, the script takes ownership and grants full control, then retries.

3. **Start phase**  
   Starts the four services again and reports their final state.

4. **Reboot prompt**  
   Asks whether to reboot immediately (recommended).

## What Gets Reset

| Folder                  | Purpose                                                                 |
|-------------------------|-------------------------------------------------------------------------|
| `SoftwareDistribution`  | Windows Update agent datastore (`DataStore.edb`) and download cache. This is the primary source of “pending download” / `0x80240007` issues. |
| `catroot2`              | Cryptographic catalog cache used to verify update signatures. Secondary but routinely reset with the agent. |

Both folders are recreated automatically the next time the services start and Windows Update runs. Installed updates and update history are not lost.

## After Running

1. Reboot (strongly recommended).
2. Open **Settings → Windows Update** and let it scan.
3. Pending updates should begin downloading again.  
   If a specific update still fails, generate a fresh `WindowsUpdate.log` and inspect the new error.

## Notes / Limitations

- The script continues even if one service cannot be stopped, but a locked `cryptsvc` can still prevent the `catroot2` rename.
- It does not touch Windows Update policies, WSUS configuration, or Delivery Optimization settings.
- On domain-joined or managed devices, Group Policy or management tools may re-apply settings after reboot.
- Always run from an elevated session; otherwise the renames and service stops will fail.

## Example Output (minimal)

```
=== Windows Update Component Reset ===
Minimal output mode. Use -Verbose or -v for details.

Phase 1: Stopping services...
  [OK]   bits stopped (attempt 1).
  [OK]   wuauserv stopped (attempt 1).
  [WARN] cryptsvc did not stop gracefully. Forcing stop...
  [OK]   cryptsvc force-stopped.
  [OK]   msiserver stopped (attempt 1).

Phase 2: Renaming folders...
  Renaming C:\Windows\SoftwareDistribution -> SoftwareDistribution.bak
  [OK]   Renamed successfully.
  Renaming C:\Windows\System32\catroot2 -> catroot2.bak
  [OK]   Renamed successfully.

Phase 3: Starting services...
  [OK]   bits started.
  ...

A reboot is strongly recommended so the new folders are fully initialized.

Reboot now? (Y/N)
```

## License / Use

Free for personal and internal IT toolkit use. No warranty; test in your environment.
