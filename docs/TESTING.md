# Testing checklist

Test on a throwaway Windows first. Never test a new version straight on the PC you depend on.

## 1. Static checks (no Windows needed beyond PowerShell)

These run automatically in GitHub Actions on every push (`.github/workflows/ci.yml`). To run them by hand in Windows PowerShell:

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error, Warning
.\WinOptSuite.ps1 -SelfTest        # checks config.ini and shows which tools this PC supports; changes nothing
.\Optimize.ps1 -DryRun             # shows what Maintenance would clean; changes nothing
```

Pass condition: no `Error` results, `-SelfTest` exits 0 and lists all five config sections.

## 2. Windows Sandbox (quickest, free on Windows 10/11 Pro)

1. Turn on Windows Sandbox: Start → "Turn Windows features on or off" → tick **Windows Sandbox** → restart.
2. Edit `tests/WinOptSuite.wsb`: set `HostFolder` to where this repo is extracted.
3. Double-click `tests/WinOptSuite.wsb`. In the sandbox, open **WinOptSuite** on the desktop and run `WinOptSuite.bat`.

Limits inside Sandbox: System Restore is not available (the restore-point step fails; answer Y to continue), and Store apps differ from a normal install. Use it to test the menu, downloads, hash checks and the tools' screens.

## 3. Virtual machine with a snapshot (most realistic)

1. Create a VM (Hyper-V "Quick Create", VirtualBox or VMware) with a clean **Windows 11 25H2**, **Windows 11 24H2** and/or **Windows 10 22H2**.
2. Install updates, then take a snapshot / checkpoint called `clean`.
3. Copy the repo in, run `WinOptSuite.bat`, go through the checks below.
4. Revert to `clean` between runs.

## 4. What to check

| # | Check | Expected |
|---|---|---|
| 1 | Double-click `WinOptSuite.bat`, click **No** on UAC | "Administrator rights were not granted. Nothing was changed." |
| 2 | Run it again, click **Yes** | Menu shows Windows version and build |
| 3 | Disconnect network, pick [2] | Clear "No internet connection" message, back to menu |
| 4 | Pick any tool, answer anything except Y | Nothing runs, back to menu |
| 5 | First tool run | Restore point created (check with [8] → [1]); `C:\ProgramData\WinOptSuite\backups\<time>\` has 3 `.reg` files |
| 6 | Edit one `Sha256` in `config.ini`, delete `C:\ProgramData\WinOptSuite\tools`, run that tool | "SECURITY CHECK FAILED", file deleted, tool not run. Restore the value afterwards |
| 7 | [1] Quick Safe Optimize | Shows `-RunDefaultsLite -Silent -LogPath …`, asks Y for Win11Debloat, then Y again for Maintenance |
| 8 | Windows 11 24H2 | [4] Sophia greyed out with the build reason |
| 9 | Windows 10 22H2 | [5] RemoveWindowsAI greyed out |
| 10 | [5] then [8] → [5] | AI features removed, then restored by revert mode |
| 11 | [9] Update pinned versions | Shows current → latest with SHA256; answering not-Y leaves `config.ini` unchanged |
| 12 | [L] | Opens `C:\ProgramData\WinOptSuite\logs` with `*-actions.log` and `*-transcript.log` |
| 13 | After the run | No new scheduled tasks or startup entries created by WinOptSuite (Task Scheduler, Task Manager → Startup) |
