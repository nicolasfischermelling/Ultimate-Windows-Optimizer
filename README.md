# Ultimate Windows Optimizer

One double-click menu, **WinOptSuite**, that runs the best actively maintained open-source Windows optimization tools safely, plus a built-in cleanup and tuning engine.

> Use at your own risk. Every option tells you what it changes and whether you can undo it, and nothing runs until you type **Y**. Try it on a test PC or in Windows Sandbox first (see [docs/TESTING.md](docs/TESTING.md)).

## How to start

1. On GitHub: **Code → Download ZIP**. Extract the ZIP.
2. Double-click **`WinOptSuite.bat`**.
3. Click **Yes** when Windows asks for administrator rights.
4. Type the number of an option and press Enter.

Requirements: Windows 10 22H2 or Windows 11 (24H2/25H2), an internet connection, nothing else to install.

## The menu

```
 [1] Quick Safe Optimize   (recommended)
 [2] Debloat apps & telemetry      - Win11Debloat
 [3] Full tweak toolbox (GUI)      - Chris Titus WinUtil
 [4] Advanced fine-tuning          - Sophia Script
 [5] Remove Windows AI (Copilot/Recall) - RemoveWindowsAI
 [6] Privacy script generator (web) - privacy.sexy
 [7] Maintenance: disk cleanup, SFC, DISM, temp files
 [8] Restore / Undo
 [9] Update pinned tool versions
 [L] Open logs folder
 [Q] Quit
```

Options this PC can't run are shown in grey with the reason.

| Option | What it does | Risk | How to undo |
|---|---|---|---|
| **1 Quick Safe Optimize** | Runs Win11Debloat with its recommended defaults **without removing any apps** (`-RunDefaultsLite -Silent`), then option 7. Each step asks for Y. | Low | [8] → Win11Debloat restore backup, or System Restore |
| **2 Win11Debloat** | Opens Win11Debloat so you choose which apps to remove and which settings to change (telemetry, ads, Bing search, Copilot, taskbar/Start/Explorer). | Low–medium | Win11Debloat's own registry backup ([8] → 6). Removed apps: reinstall from the Microsoft Store |
| **3 WinUtil** | Opens Chris Titus WinUtil: install apps, tweaks, fixes, Windows Update settings. Nothing changes until you click an action in it. | Medium (depends on what you click) | Many tweaks have an Undo button in WinUtil; System Restore |
| **4 Sophia Script** | Downloads Sophia and opens its settings file in Notepad. Put `#` in front of anything you don't want, save, close; you're asked again before it runs. | Medium (150+ settings if left unedited) | Each setting has an opposite line; System Restore |
| **5 RemoveWindowsAI** | Removes Copilot, Recall and other AI parts of Windows 11 in **backup mode**. | Medium–high | [8] → 5 (revert mode) |
| **6 privacy.sexy** | Opens the privacy.sexy website in your browser. Nothing is downloaded or run by WinOptSuite. | None | – |
| **7 Maintenance** | Temp files, Recycle Bin, Windows Update cache, browser caches (closed browsers only), Disk Cleanup, `DISM /RestoreHealth`, `sfc /scannow`, optional drive optimization (TRIM on SSD, defrag on HDD). Built-in Windows tools only. | Low | Deleted files can't be recovered |
| **8 Restore / Undo** | List restore points, open System Restore, re-import a registry backup, undo optimizer settings, and each tool's own revert option. | – | – |
| **9 Update pinned versions** | Checks GitHub for newer tool versions and shows the new version and its SHA256. Nothing changes until you type Y. | – | Edit `config.ini` back |

## Safety built in

Before the first tool runs in a session:

1. **Restore point** — it lifts Windows' "one per 24 hours" limit for that call only. If System Protection is off, you're asked before it's turned on.
2. **Registry backup** — `HKCU` and the Windows policy keys go to `C:\ProgramData\WinOptSuite\backups\<date-time>\`.
3. **Logs** — every choice, command and exit code goes to `C:\ProgramData\WinOptSuite\logs\`, plus a full screen transcript.

Also:

- **Pinned, verified downloads.** Each tool is downloaded at a fixed version from its official GitHub release, or from a fixed commit for RemoveWindowsAI. Its SHA256 is checked against `config.ini`. If the file doesn't match, it's deleted and not run.
- **Confirmation for everything.** Each tool shows what it changes and whether it can be undone, and needs **Y**. Quick Safe asks separately for each of its two steps.
- **WinOptSuite itself never:** disables Defender, SmartScreen, UAC or Windows Update; adds antivirus exclusions; creates scheduled tasks or startup entries; or sends telemetry. The tools you run may make their own changes, as described in their option.
- **Antivirus warnings.** Some antivirus products flag tweaking scripts (a known false positive). WinOptSuite tells you this and never bypasses your antivirus.

## Which tool versions are used

Pinned in [`config.ini`](config.ini). Update them with menu [9].

| Tool | Pinned | Hash |
|---|---|---|
| WinUtil | `26.09.29` (release file `winutil.ps1`) | pinned |
| Win11Debloat | `2026.08.24` (release source archive, the same file its official launcher uses) | shown on first download and saved after you confirm |
| Sophia Script | Windows 11: `7.3.0`, Windows 10: `6.3.0` (release `7.3.0`) | pinned |
| RemoveWindowsAI | commit `fd90ea3` (the project has no releases) | pinned |

### Changes found in the upstream docs (checked 2026-10-04)

- **WinUtil** now publishes GitHub releases with a `winutil.ps1` file, so it's pinned and hash-checked like the others instead of running `irm christitus.com/win | iex` live.
- **Win11Debloat** has `-RunDefaultsLite` (default settings without removing apps), which Quick Safe uses. Since 2026.05.10 it also saves its own registry backup.
- **Sophia Script** has separate downloads per Windows version. The current Windows 11 version only runs on **25H2 (build 26200) or newer**, so option 4 is unavailable on 24H2.
- **RemoveWindowsAI** has no releases, so it's pinned to a commit. While running, it downloads a few helper files from its GitHub page; those aren't covered by the pin. `-AllOptions` isn't used. WinOptSuite passes an explicit list (in `config.ini`) that leaves out:
  - `UpdateCleanupCheck`, which creates a scheduled task
  - `DisableDefenderAI`, which touches Defender
  - `PreventAIPackageReinstall` and `RemoveCBSPackages`, which modify the Windows servicing store

## Built-in optimizer (used by option 7)

`Optimize.ps1` can also be run on its own from an administrator PowerShell window:

```powershell
.\Optimize.ps1 -DryRun            # preview, changes nothing
.\Optimize.ps1                    # cleanup + performance tuning (power plan, startup apps, visual effects, background apps, optional services)
.\Optimize.ps1 -Mode Cleanup      # cleanup only
.\Undo.ps1                        # revert the setting changes of the last run
```

It flags bloatware but never uninstalls anything. Lists of apps and services it handles are in `config/Lists.psd1`.

## Files

| File | Purpose |
|---|---|
| `WinOptSuite.bat` | Double-click launcher: admin prompt, starts the menu |
| `WinOptSuite.ps1` | Menu, safety layer, downloads and hash checks |
| `config.ini` | Pinned tool versions, URLs, SHA256, RemoveWindowsAI option list |
| `Optimize.ps1`, `Undo.ps1`, `src/`, `config/` | Built-in cleanup/tuning engine |
| `docs/TESTING.md` | Test checklist (static checks, Windows Sandbox, VM) |
| `tests/WinOptSuite.wsb` | Windows Sandbox configuration |
| `THIRD-PARTY-NOTICES.txt` | Credits and licenses |

## Credits and licenses

WinOptSuite is a launcher: it doesn't copy or change the tools' code, it downloads them from their official sources.

- [WinUtil](https://github.com/ChrisTitusTech/winutil) — Chris Titus Tech, MIT
- [Win11Debloat](https://github.com/Raphire/Win11Debloat) — Raphire, MIT
- [Sophia Script for Windows](https://github.com/farag2/Sophia-Script-for-Windows) — farag2 / Team Sophia, MIT
- [RemoveWindowsAI](https://github.com/zoicware/RemoveWindowsAI) — zoicware, MIT
- [privacy.sexy](https://github.com/undergroundwires/privacy.sexy) — undergroundwires, AGPL-3.0 (only linked, not redistributed)

This repository: MIT (see `LICENSE`).
