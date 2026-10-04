# Ultimate Windows Optimizer

Full-auto cleanup and performance tuning for Windows 10/11, in plain PowerShell. One run, no per-step prompts, a summary at the end, and an undo for every setting it changes.

## Quick start

1. Download the repo (Code → Download ZIP) and extract it.
2. Double-click `Run-Optimizer.cmd` and accept the UAC prompt.

Or from an elevated Windows PowerShell 5.1 prompt:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Optimize.ps1 -DryRun      # preview, changes nothing
.\Optimize.ps1              # full run
```

Use Windows PowerShell 5.1 (`powershell.exe`), not PowerShell 7 — the Appx cmdlets are unreliable under 7.

## What it does

| Pass | Actions |
|---|---|
| Safety | Creates a System Restore point; journals every registry, service and power-plan change. |
| Cleanup | User and Windows temp, Recycle Bin, Windows Update download cache, Delivery Optimization cache, Chrome/Edge/Brave caches (skipped if the browser is running), Disk Cleanup categories (temp, thumbnails, update cleanup, error reports, logs), `Windows.old` if ≥ `-WindowsOldMinGB` (default 2 GB). |
| Performance | Power plan → High performance (Balanced on a laptop running on battery); disables known low-value startup apps; visual effects → best performance with font smoothing kept; disables background activity for preinstalled Store apps; `Optimize-Volume` on fixed drives (TRIM for SSD, defrag for HDD). |
| Services | Fax disabled; Print Spooler disabled only if no physical printer exists; Xbox services disabled only on PCs with no game launcher installed. Core services (Windows Update, Defender, networking) are never touched. |
| Audit | Lists bloatware candidates (Store apps and desktop programs). **Nothing is uninstalled.** |

Unknown startup entries are left enabled and listed for review. Antivirus, drivers, audio, input devices and cloud-sync tools are always kept.

## Output

`logs/` receives, per run:

- `optimize-<timestamp>.log` — full log
- `report-<timestamp>.json` — disk freed, startup items disabled, power plan, flagged items
- `journal-<timestamp>.json` — change journal used by `Undo.ps1`

## Parameters

| Parameter | Values | Default |
|---|---|---|
| `-DryRun` | switch | off |
| `-Mode` | `All`, `Cleanup`, `Performance` | `All` |
| `-VisualEffects` | `BestPerformance`, `Skip` | `BestPerformance` |
| `-Gaming` | `Auto`, `Yes`, `No` | `Auto` (detects Steam/Epic/Battle.net/EA/Ubisoft/GOG/Riot) |
| `-WindowsOldMinGB` | 0–1000 | 2 |
| `-SkipRestorePoint` | switch | off |

## Undo

```powershell
.\Undo.ps1                                   # reverts the latest run
.\Undo.ps1 -JournalPath .\logs\journal-<timestamp>.json
```

Deleted files cannot be restored. Windows limits restore points to one per 24 h by default; if one was skipped, the log says so.

## Customising

All app/service/category lists are regex patterns in `config/Lists.psd1`. Add a pattern to `StartupKeep` to protect an app, or to `StartupDisable` to have it disabled automatically.

## Known limits

- Startup "disabled" state uses the same `StartupApproved` registry format as Task Manager; Store-app startup tasks are not handled.
- Background-app settings use the per-app `BackgroundAccessApplications` keys; behaviour on newer Windows 11 builds is not verified.
- Visual-effect and service changes need a sign-out or restart.

## License

MIT
