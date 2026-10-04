<#
.SYNOPSIS
    WinOptSuite - one menu for the main open-source Windows optimization tools.

.DESCRIPTION
    Started by WinOptSuite.bat (which handles the Administrator prompt).
    Downloads each tool from its official source at a pinned version, checks its SHA256,
    and runs it only after a safety layer (restore point, registry backup, log) and an
    explicit "Y" from the user. Nothing runs in the background, nothing is scheduled.

.PARAMETER SelfTest
    Non-interactive check used by CI: loads config, detects the OS and prints tool support. Changes nothing.
#>
[CmdletBinding()]
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Root = $PSScriptRoot
$script:ConfigPath = Join-Path $Root 'config.ini'
$script:DataRoot = Join-Path $env:ProgramData 'WinOptSuite'
$script:ToolsDir = Join-Path $DataRoot 'tools'
$script:BackupsDir = Join-Path $DataRoot 'backups'
$script:LogsDir = Join-Path $DataRoot 'logs'
$script:SafetyDone = $false
$script:UserAgent = 'WinOptSuite'

# ---------------------------------------------------------------- console helpers

function Write-Info([string]$Text) { Write-Host $Text }
function Write-Ok([string]$Text) { Write-Host $Text -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host $Text -ForegroundColor Yellow }
function Write-Bad([string]$Text) { Write-Host $Text -ForegroundColor Red }

function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
}

function Wait-Enter { [void](Read-Host 'Press Enter to go back to the menu') }

function Read-YesNo([string]$Question) {
    $answer = Read-Host "$Question Type Y to continue, anything else to cancel"
    return ($answer -eq 'Y' -or $answer -eq 'y')
}

# Shows what a step changes and whether it can be undone, then requires "Y".
function Confirm-Step {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Changes,
        [Parameter(Mandatory)][string]$Reversible,
        [string[]]$Notes = @()
    )
    Write-Title $Name
    Write-Info 'What it will change:'
    foreach ($c in $Changes) { Write-Info "  - $c" }
    Write-Info ''
    Write-Info "Can it be undone? $Reversible"
    foreach ($n in $Notes) { Write-Warn "Note: $n" }
    Write-Info ''
    $ok = Read-YesNo 'Run it now?'
    Write-Log "Confirm '$Name': $(if ($ok) { 'YES' } else { 'cancelled' })"
    return $ok
}

# Action log: every choice, command line and exit code (screen output goes to the transcript).
function Write-Log([string]$Text) {
    if (-not $script:ActionLog) { return }
    Add-Content -LiteralPath $script:ActionLog -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Text" -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Show-AntivirusNotice {
    Write-Warn 'Antivirus notice: some antivirus products flag Windows tweaking scripts as suspicious (a known false positive).'
    Write-Warn 'WinOptSuite never adds antivirus exclusions. If your antivirus blocks a tool, the tool stops and you are returned to the menu.'
}

# ---------------------------------------------------------------- config.ini

function Read-Ini {
    $ini = [ordered]@{}
    $section = $null
    foreach ($line in Get-Content -LiteralPath $script:ConfigPath) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith(';') -or $t.StartsWith('#')) { continue }
        if ($t -match '^\[(.+)\]$') { $section = $Matches[1]; $ini[$section] = [ordered]@{}; continue }
        if ($section -and $t -match '^([^=]+)=(.*)$') { $ini[$section][$Matches[1].Trim()] = $Matches[2].Trim() }
    }
    return $ini
}

# Updates one key in place, keeping comments and order.
function Set-IniValue {
    param([string]$Section, [string]$Key, [string]$Value)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($l in Get-Content -LiteralPath $script:ConfigPath) { $lines.Add($l) }
    $inSection = $false; $headerIndex = -1; $done = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $t = $lines[$i].Trim()
        if ($t -match '^\[(.+)\]$') {
            if ($inSection) { break }
            $inSection = ($Matches[1] -eq $Section)
            if ($inSection) { $headerIndex = $i }
            continue
        }
        if ($inSection -and $t -match "^$([regex]::Escape($Key))\s*=") {
            $lines[$i] = "$Key=$Value"; $done = $true; break
        }
    }
    if (-not $done) {
        if ($headerIndex -lt 0) { throw "Section [$Section] not found in config.ini" }
        $lines.Insert($headerIndex + 1, "$Key=$Value")
    }
    Set-Content -LiteralPath $script:ConfigPath -Value $lines -Encoding ASCII
}

function Get-ToolUrl($Tool) {
    return $Tool.UrlTemplate.Replace('{tag}', $Tool.ReleaseTag).Replace('{version}', $Tool.Version)
}

# ---------------------------------------------------------------- system checks

function Get-OsInfo {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$cv.CurrentBuild
    $display = if ($cv.PSObject.Properties['DisplayVersion']) { $cv.DisplayVersion } elseif ($cv.PSObject.Properties['ReleaseId']) { $cv.ReleaseId } else { '' }
    $ubr = if ($cv.PSObject.Properties['UBR']) { $cv.UBR } else { 0 }
    [pscustomobject]@{
        Build     = $build
        UBR       = $ubr
        Display   = $display
        Edition   = [string]$cv.EditionID
        IsWin11   = $build -ge 22000
        IsLTSC    = ([string]$cv.EditionID) -match 'EnterpriseS|IoTEnterpriseS'
        IsArm     = $env:PROCESSOR_ARCHITECTURE -eq 'ARM64'
        Name      = if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
    }
}

# Returns $null when the tool supports this PC, otherwise the reason it is blocked.
function Get-BlockReason([string]$ToolKey) {
    $os = $script:Os
    if ($os.Build -lt 19045 -and $ToolKey -ne 'privacy') { return "needs Windows 10 22H2 (build 19045) or Windows 11; this PC is build $($os.Build)." }
    switch ($ToolKey) {
        'Sophia' {
            if ($os.IsLTSC) { return 'LTSC editions need a different Sophia package; not handled by WinOptSuite.' }
            if ($os.IsArm) { return 'Windows on ARM needs a different Sophia package; not handled by WinOptSuite.' }
            $t = Get-SophiaTool
            if ($os.Build -lt [int]$t.MinBuild) { return "the pinned Sophia $($t.Version) for $($os.Name) needs build $($t.MinBuild) or newer (this PC: $($os.Build), $($os.Display))." }
        }
        'RemoveWindowsAI' {
            if (-not $os.IsWin11) { return 'Windows 10 has no Copilot+/Recall AI components; this tool targets Windows 11.' }
        }
    }
    return $null
}

function Test-Internet {
    try {
        $null = Invoke-WebRequest -Uri 'https://github.com' -Method Head -UseBasicParsing -TimeoutSec 15
        return $true
    }
    catch { return $false }
}

function Assert-Online {
    if (Test-Internet) { return $true }
    Write-Bad 'No internet connection (could not reach github.com). Connect to the internet and try again.'
    Write-Log 'Offline: github.com not reachable'
    return $false
}

# ---------------------------------------------------------------- safety layer

function New-SafetyRestorePoint {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $name = 'SystemRestorePointCreationFrequency'
    $item = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    $hadValue = $item -and $item.PSObject.Properties[$name]
    $oldValue = if ($hadValue) { $item.$name } else { $null }
    try {
        # Windows allows one restore point per 24 h by default; lift that only for this call.
        New-ItemProperty -Path $key -Name $name -Value 0 -PropertyType DWord -Force | Out-Null
        try {
            Checkpoint-Computer -Description "WinOptSuite $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -RestorePointType MODIFY_SETTINGS
        }
        catch {
            Write-Warn "Restore point failed: $($_.Exception.Message)"
            Write-Warn 'This usually means System Protection is turned off for the system drive.'
            if (-not (Read-YesNo "Turn on System Protection for $env:SystemDrive (uses a few GB of disk)?")) { throw 'System Protection not enabled' }
            Enable-ComputerRestore -Drive "$env:SystemDrive\"
            Write-Log "System Protection enabled on $env:SystemDrive"
            Checkpoint-Computer -Description "WinOptSuite $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -RestorePointType MODIFY_SETTINGS
        }
        Write-Ok 'Restore point created.'
        Write-Log 'Restore point created'
        return $true
    }
    catch {
        Write-Bad "No restore point: $($_.Exception.Message)"
        Write-Log "Restore point FAILED: $($_.Exception.Message)"
        return $false
    }
    finally {
        if ($hadValue) { New-ItemProperty -Path $key -Name $name -Value $oldValue -PropertyType DWord -Force | Out-Null }
        else { Remove-ItemProperty -Path $key -Name $name -ErrorAction SilentlyContinue }
    }
}

function Backup-Registry {
    $dir = Join-Path $script:BackupsDir (Get-Date -Format 'yyyyMMdd-HHmmss')
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $hives = [ordered]@{
        'HKCU.reg'                 = 'HKCU'
        'HKLM-Policies.reg'        = 'HKLM\SOFTWARE\Policies'
        'HKLM-WindowsPolicies.reg' = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies'
    }
    $allOk = $true
    foreach ($file in $hives.Keys) {
        $code = Invoke-External -FilePath 'reg.exe' -ArgumentList @('export', $hives[$file], (Join-Path $dir $file), '/y') -Quiet
        if ($code -ne 0) { $allOk = $false; Write-Bad "Registry export of $($hives[$file]) failed (exit code $code)." }
    }
    if ($allOk) { Write-Ok "Registry backup saved to $dir" }
    return $allOk
}

# Runs once per session, before the first tool.
function Invoke-SafetyLayer {
    if ($script:SafetyDone) { return $true }
    Write-Title 'Safety first: restore point + registry backup'
    $rp = New-SafetyRestorePoint
    $rb = Backup-Registry
    if (-not ($rp -and $rb)) {
        Write-Warn 'The safety layer did not fully complete (see messages above).'
        if (-not (Read-YesNo 'Continue anyway?')) { return $false }
    }
    $script:SafetyDone = $true
    return $true
}

# ---------------------------------------------------------------- processes

function ConvertTo-Arg([string]$Value) {
    if ($Value -match '[\s"]') { return '"' + $Value.Replace('"', '\"') + '"' }
    return $Value
}

# Runs a program in this console window, logs the command line and exit code.
function Invoke-External {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = $script:Root,
        [switch]$Quiet
    )
    $argLine = ($ArgumentList | ForEach-Object { ConvertTo-Arg $_ }) -join ' '
    Write-Log "RUN: $FilePath $argLine"
    $params = @{ FilePath = $FilePath; WorkingDirectory = $WorkingDirectory; Wait = $true; PassThru = $true; NoNewWindow = $true }
    if ($argLine) { $params.ArgumentList = $argLine }
    if ($Quiet) {
        $params.RedirectStandardOutput = Join-Path $env:TEMP 'winoptsuite-stdout.txt'
        $params.RedirectStandardError = Join-Path $env:TEMP 'winoptsuite-stderr.txt'
    }
    try {
        $p = Start-Process @params
        $code = $p.ExitCode
    }
    catch {
        Write-Log "RUN FAILED: $($_.Exception.Message)"
        Write-Bad "Could not start $FilePath : $($_.Exception.Message)"
        return -1
    }
    Write-Log "EXIT $code : $FilePath"
    return $code
}

function Invoke-PowerShellFile {
    param([Parameter(Mandatory)][string]$File, [string[]]$Arguments = @(), [string]$WorkingDirectory)
    if (-not $WorkingDirectory) { $WorkingDirectory = Split-Path -Parent $File }
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return Invoke-External -FilePath $ps -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $File) + $Arguments) -WorkingDirectory $WorkingDirectory
}

# Like Invoke-PowerShellFile but through -Command, so "-Options A,B,C" binds as an array.
function Invoke-PowerShellScriptCommand {
    param([Parameter(Mandatory)][string]$File, [string]$ArgumentText = '')
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $command = "& '$($File.Replace("'", "''"))' $ArgumentText; exit `$LASTEXITCODE"
    return Invoke-External -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $command) -WorkingDirectory (Split-Path -Parent $File)
}

function Show-Result([string]$Name, [int]$Code) {
    if ($Code -eq 0) { Write-Ok "$Name finished (exit code 0)." }
    else { Write-Bad "$Name ended with exit code $Code. Check the log: $script:ActionLog" }
}

# ---------------------------------------------------------------- downloads

function Invoke-Download([string]$Url, [string]$OutFile) {
    Write-Log "DOWNLOAD $Url"
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -Headers @{ 'User-Agent' = $script:UserAgent }
}

# Downloads (or reuses) the pinned file for a tool and verifies its SHA256. Returns the folder holding it.
function Get-PinnedTool {
    param([Parameter(Mandatory)][string]$Section)
    $tool = (Read-Ini)[$Section]
    $dir = Join-Path $script:ToolsDir (Join-Path $Section $tool.Version.Substring(0, [Math]::Min(12, $tool.Version.Length)))
    $file = Join-Path $dir $tool.File
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    if (-not (Test-Path -LiteralPath $file)) {
        if (-not (Assert-Online)) { return $null }
        Write-Info "Downloading $Section $($tool.Version)..."
        try { Invoke-Download -Url (Get-ToolUrl $tool) -OutFile $file }
        catch {
            Write-Bad "Download failed: $($_.Exception.Message)"
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            return $null
        }
    }

    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    Write-Log "SHA256 $Section $hash"
    if (-not $tool.Sha256) {
        Write-Warn "No pinned hash for $Section $($tool.Version) yet."
        Write-Info "Downloaded from: $(Get-ToolUrl $tool)"
        Write-Info "SHA256: $hash"
        if (-not (Read-YesNo 'Trust this file and save its hash to config.ini?')) {
            Remove-Item -LiteralPath $file -Force
            return $null
        }
        Set-IniValue -Section $Section -Key 'Sha256' -Value $hash
        Write-Log "Hash pinned for $Section"
    }
    elseif ($hash -ne $tool.Sha256.ToUpper()) {
        Write-Bad "SECURITY CHECK FAILED for $Section : the file does not match the pinned SHA256."
        Write-Bad "Expected $($tool.Sha256)"
        Write-Bad "Got      $hash"
        Write-Log "HASH MISMATCH $Section"
        Remove-Item -LiteralPath $file -Force
        return $null
    }
    else { Write-Ok "$Section $($tool.Version): SHA256 verified." }

    if ($file -like '*.zip') {
        $extract = Join-Path $dir 'extracted'
        if (-not (Test-Path -LiteralPath $extract)) { Expand-Archive -LiteralPath $file -DestinationPath $extract -Force }
        return $extract
    }
    return $dir
}

function Find-File([string]$Folder, [string]$Name) {
    Get-ChildItem -LiteralPath $Folder -Recurse -Filter $Name -File -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Get-SophiaTool {
    $ini = Read-Ini
    if ($script:Os.IsWin11) { $s = 'SophiaWin11' } else { $s = 'SophiaWin10' }
    $t = $ini[$s]
    $t['Section'] = $s
    return $t
}

# ---------------------------------------------------------------- tools

function Test-ToolAllowed([string]$Key, [string]$Label) {
    $reason = Get-BlockReason $Key
    if ($reason) {
        Write-Bad "$Label is not available on this PC: $reason"
        Write-Log "BLOCKED $Label : $reason"
        return $false
    }
    return $true
}

function Invoke-Win11Debloat {
    param([switch]$QuickSafe)
    if (-not (Test-ToolAllowed 'Win11Debloat' 'Win11Debloat')) { return $false }
    $tool = (Read-Ini)['Win11Debloat']
    $toolArgs = @('-LogPath', $script:LogsDir)
    if ($QuickSafe) {
        $quick = @($tool.QuickSafeArgs -split '\s+' | Where-Object { $_ })
        $toolArgs = $quick + $toolArgs
        $changes = @(
            'Win11Debloat default settings: telemetry, tips/suggestions and ads, Bing in search, Copilot/Recall/Click to Do, widgets, Edge ads, show file extensions (see README for the full list).',
            'Apps are NOT uninstalled (-RunDefaultsLite).',
            "Exact command: Win11Debloat.ps1 $($toolArgs -join ' ')"
        )
    }
    else {
        $changes = @('Opens the Win11Debloat window. You pick what to remove or change; nothing happens until you apply it there.')
    }
    Show-AntivirusNotice
    if (-not (Confirm-Step -Name "Win11Debloat $($tool.Version)" -Changes $changes `
            -Reversible 'Yes for settings: Win11Debloat saves its own registry backup (Options > Restore backup), plus the WinOptSuite restore point. Removed apps must be reinstalled from the Microsoft Store.')) { return $false }
    if (-not (Invoke-SafetyLayer)) { return $false }
    $folder = Get-PinnedTool -Section 'Win11Debloat'
    if (-not $folder) { return $false }
    $script = Find-File $folder 'Win11Debloat.ps1'
    if (-not $script) { Write-Bad 'Win11Debloat.ps1 not found in the download.'; return $false }
    $code = Invoke-PowerShellFile -File $script.FullName -Arguments $toolArgs
    Show-Result 'Win11Debloat' $code
    return ($code -eq 0)
}

function Invoke-WinUtil {
    if (-not (Test-ToolAllowed 'WinUtil' 'WinUtil')) { return }
    $tool = (Read-Ini)['WinUtil']
    Show-AntivirusNotice
    if (-not (Confirm-Step -Name "Chris Titus WinUtil $($tool.Version)" `
            -Changes @('Opens the WinUtil window (install apps, tweaks, fixes, Windows Update settings). Nothing changes until you click an action there.') `
            -Reversible 'Partly. Many tweaks have an "Undo" button in WinUtil; installed apps can be uninstalled normally. The WinOptSuite restore point covers the rest.' `
            -Notes @('WinUtil installs apps through winget/chocolatey, which download from the internet while it runs.'))) { return }
    if (-not (Invoke-SafetyLayer)) { return }
    $folder = Get-PinnedTool -Section 'WinUtil'
    if (-not $folder) { return }
    Show-Result 'WinUtil' (Invoke-PowerShellFile -File (Join-Path $folder $tool.File))
}

function Invoke-Sophia {
    if (-not (Test-ToolAllowed 'Sophia' 'Sophia Script')) { return }
    $tool = Get-SophiaTool
    if (-not (Confirm-Step -Name "Sophia Script $($tool.Version) for $($script:Os.Name)" `
            -Changes @(
                'Downloads Sophia Script and opens its preset file (Sophia.ps1) in Notepad.',
                'Lines without # in front will run. Put # in front of anything you do NOT want, save, and close Notepad.',
                'After Notepad closes you are asked once more before anything runs.'
            ) `
            -Reversible 'Yes, per setting: most Sophia functions have an opposite (-Enable / -Disable) you can run later, plus the WinOptSuite restore point.' `
            -Notes @('Unedited, Sophia.ps1 applies its whole preset (about 150 settings). Review it first.'))) { return }
    if (-not (Invoke-SafetyLayer)) { return }
    $folder = Get-PinnedTool -Section $tool.Section
    if (-not $folder) { return }
    $preset = Find-File $folder 'Sophia.ps1'
    if (-not $preset) { Write-Bad 'Sophia.ps1 not found in the download.'; return }
    Write-Info "Opening $($preset.FullName) in Notepad."
    $null = Invoke-External -FilePath 'notepad.exe' -ArgumentList @($preset.FullName)
    Write-Info 'Edit, save (Ctrl+S) and close Notepad, then come back to this window.'
    if (-not (Read-YesNo 'Run Sophia.ps1 with your edits now?')) { Write-Log 'Sophia cancelled after edit'; return }
    Show-Result 'Sophia Script' (Invoke-PowerShellFile -File $preset.FullName)
}

function Invoke-RemoveWindowsAI {
    param([switch]$Revert)
    if (-not (Test-ToolAllowed 'RemoveWindowsAI' 'RemoveWindowsAI')) { return }
    $tool = (Read-Ini)['RemoveWindowsAI']
    $options = $tool.Options
    $mode = if ($Revert) { '-revertMode' } else { '-backupMode' }
    $optionList = ($options -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[A-Za-z]+$' }) -join ','
    $argText = "-nonInteractive $mode -Options $optionList"
    Show-AntivirusNotice
    if ($Revert) {
        $ok = Confirm-Step -Name 'RemoveWindowsAI - revert' -Changes @("Restores the AI features removed earlier: $options", "Exact command: RemoveWindowsAi.ps1 $argText") `
            -Reversible 'You can run the removal again.' -Notes @('A full revert only works if the removal ran in backup mode (WinOptSuite always uses it).')
    }
    else {
        $ok = Confirm-Step -Name "RemoveWindowsAI (commit $($tool.Version.Substring(0, 7)))" `
            -Changes @("Removes / disables Windows AI features: $options", "Exact command: RemoveWindowsAi.ps1 $argText") `
            -Reversible 'Yes: runs in backup mode (it also makes its own restore point); use menu [8] > RemoveWindowsAI revert.' `
            -Notes @('Skipped on purpose: the scheduled re-check task, Defender AI changes and Windows servicing-store changes.',
                'While running, this tool downloads a few helper files from its GitHub page (not covered by the pinned hash).')
    }
    if (-not $ok) { return }
    if (-not (Invoke-SafetyLayer)) { return }
    $folder = Get-PinnedTool -Section 'RemoveWindowsAI'
    if (-not $folder) { return }
    Show-Result 'RemoveWindowsAI' (Invoke-PowerShellScriptCommand -File (Join-Path $folder $tool.File) -ArgumentText $argText)
}

function Open-PrivacySexy {
    Write-Title 'privacy.sexy (opens in your browser)'
    Write-Info 'privacy.sexy is a website where you tick privacy settings and it writes a script you can review and run yourself.'
    Write-Info 'WinOptSuite only opens the page; it does not download or run anything from it.'
    Write-Info 'Licence: AGPL-3.0. Source: https://github.com/undergroundwires/privacy.sexy'
    if (Read-YesNo 'Open https://privacy.sexy now?') {
        Start-Process 'https://privacy.sexy'
        Write-Log 'Opened privacy.sexy'
    }
}

function Invoke-Maintenance {
    param([switch]$SkipConfirm)
    if (-not $SkipConfirm) {
        if (-not (Confirm-Step -Name 'Maintenance (built-in Windows tools only)' `
                -Changes @(
                    'Deletes temp files (user and Windows temp; locked files are skipped), empties the Recycle Bin, clears Windows Update download cache and browser caches (closed browsers only).',
                    'Runs Disk Cleanup (cleanmgr) for temp, thumbnails, update leftovers, error reports and logs.',
                    'Runs DISM /Online /Cleanup-Image /RestoreHealth, then sfc /scannow (can take 10-30 minutes).',
                    'Optional at the end: drive optimization (TRIM for SSD, defrag for HDD).'
                ) `
                -Reversible 'Deleted files cannot be restored. DISM/SFC only repair Windows system files.')) { return }
    }
    if (-not (Invoke-SafetyLayer)) { return }

    Write-Title 'Step 1/3: cleanup'
    Show-Result 'Cleanup' (Invoke-PowerShellFile -File (Join-Path $script:Root 'Optimize.ps1') -Arguments @('-Mode', 'Cleanup', '-SkipRestorePoint') -WorkingDirectory $script:Root)

    Write-Title 'Step 2/3: DISM health restore'
    Show-Result 'DISM' (Invoke-External -FilePath 'DISM.exe' -ArgumentList @('/Online', '/Cleanup-Image', '/RestoreHealth'))

    Write-Title 'Step 3/3: System File Checker'
    Show-Result 'SFC' (Invoke-External -FilePath 'sfc.exe' -ArgumentList @('/scannow'))

    if (Read-YesNo 'Also optimize drives now (TRIM on SSD, defrag on HDD; type of drive is detected automatically)?') {
        Show-Result 'Drive optimization' (Invoke-PowerShellFile -File (Join-Path $script:Root 'Optimize.ps1') -Arguments @('-Mode', 'Drives', '-SkipRestorePoint') -WorkingDirectory $script:Root)
    }
}

function Invoke-QuickSafe {
    Write-Title 'Quick Safe Optimize'
    Write-Info 'Two steps, each asks for your Y first:'
    Write-Info '  1. Win11Debloat with its recommended defaults (no apps removed).'
    Write-Info '  2. Maintenance: cleanup, Disk Cleanup, DISM, SFC.'
    $null = Invoke-Win11Debloat -QuickSafe
    Invoke-Maintenance
}

# ---------------------------------------------------------------- restore / undo

function Import-RegistryBackup {
    $sets = @(Get-ChildItem -LiteralPath $script:BackupsDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($sets.Count -eq 0) { Write-Warn 'No registry backups found.'; return }
    for ($i = 0; $i -lt $sets.Count; $i++) { Write-Info ("  [{0}] {1}" -f ($i + 1), $sets[$i].Name) }
    $pick = Read-Host 'Number of the backup to restore (Enter to cancel)'
    $n = 0
    if (-not [int]::TryParse($pick, [ref]$n) -or $n -lt 1 -or $n -gt $sets.Count) { return }
    $set = $sets[$n - 1]
    if (-not (Confirm-Step -Name "Re-import registry backup $($set.Name)" `
            -Changes @('Writes the saved values back into HKCU and the policy keys.') `
            -Reversible 'Make a new backup first if unsure (any tool run does this).' `
            -Notes @('Values added after the backup are not removed; for a full rollback use System Restore.'))) { return }
    foreach ($f in Get-ChildItem -LiteralPath $set.FullName -Filter '*.reg') {
        $code = Invoke-External -FilePath 'reg.exe' -ArgumentList @('import', $f.FullName) -Quiet
        Show-Result "Import $($f.Name)" $code
    }
    Write-Info 'Sign out or restart to apply.'
}

function Show-RestoreMenu {
    while ($true) {
        Write-Title 'Restore / Undo'
        Write-Info ' [1] List restore points'
        Write-Info ' [2] Open System Restore (roll the whole PC back to a restore point)'
        Write-Info ' [3] Re-import a WinOptSuite registry backup'
        Write-Info ' [4] Undo maintenance/optimizer setting changes (Undo.ps1)'
        Write-Info ' [5] RemoveWindowsAI: revert mode'
        Write-Info ' [6] Win11Debloat: open it to use Options > Restore backup'
        Write-Info ' [7] Sophia Script: how to revert'
        Write-Info ' [B] Back'
        $c = (Read-Host 'Choose').Trim().ToUpper()
        Write-Log "Restore menu choice: $c"
        try {
            switch ($c) {
                '1' { Get-ComputerRestorePoint | Format-Table SequenceNumber, CreationTime, Description -AutoSize | Out-Host; Wait-Enter }
                '2' { $null = Invoke-External -FilePath 'rstrui.exe' }
                '3' { Import-RegistryBackup; Wait-Enter }
                '4' {
                    if (Read-YesNo 'Revert the latest Optimize.ps1 setting changes (registry, services, power plan)?') {
                        Show-Result 'Undo' (Invoke-PowerShellFile -File (Join-Path $script:Root 'Undo.ps1') -WorkingDirectory $script:Root)
                    }
                    Wait-Enter
                }
                '5' { Invoke-RemoveWindowsAI -Revert; Wait-Enter }
                '6' {
                    Write-Info 'Win11Debloat will open. In its window: Options (top right) > Restore backup > Restore Registry Backup.'
                    Write-Info 'Removed apps are reinstalled from the Microsoft Store.'
                    if (Read-YesNo 'Open Win11Debloat?') {
                        $folder = Get-PinnedTool -Section 'Win11Debloat'
                        if ($folder) { $s = Find-File $folder 'Win11Debloat.ps1'; if ($s) { Show-Result 'Win11Debloat' (Invoke-PowerShellFile -File $s.FullName) } }
                    }
                    Wait-Enter
                }
                '7' {
                    Write-Info 'Sophia has no single undo. Each setting has an opposite: for example "DiagTrackService -Disable" is undone by "DiagTrackService -Enable".'
                    Write-Info 'Run menu [4] again and, in Notepad, enable the opposite lines (they are listed right under each setting, commented with #).'
                    Write-Info 'For a full rollback use [2] System Restore.'
                    Wait-Enter
                }
                'B' { return }
            }
        }
        catch { Write-Bad "Error: $($_.Exception.Message)"; Write-Log "ERROR restore menu: $($_.Exception.Message)"; Wait-Enter }
    }
}

# ---------------------------------------------------------------- update pinned versions

function Get-GitHubJson([string]$Url) {
    Invoke-RestMethod -Uri $Url -UseBasicParsing -Headers @{ 'User-Agent' = $script:UserAgent; 'Accept' = 'application/vnd.github+json' }
}

function Update-PinnedTool {
    param([string]$Section, [string]$NewTag, [string]$NewVersion)
    $ini = Read-Ini
    $tool = $ini[$Section]
    if ($tool.ReleaseTag -eq $NewTag -and $tool.Version -eq $NewVersion) {
        Write-Ok "$Section is up to date ($($tool.Version))."
        return
    }
    $candidate = [ordered]@{ UrlTemplate = $tool.UrlTemplate; ReleaseTag = $NewTag; Version = $NewVersion }
    $url = Get-ToolUrl $candidate
    Write-Info "$Section : $($tool.Version)  ->  $NewVersion"
    $tmp = Join-Path $env:TEMP "winoptsuite-$Section.tmp"
    try { Invoke-Download -Url $url -OutFile $tmp }
    catch { Write-Bad "Download failed: $($_.Exception.Message)"; return }
    $hash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
    Remove-Item -LiteralPath $tmp -Force
    Write-Info "  URL:    $url"
    Write-Info "  SHA256: $hash"
    Write-Info "  Release notes: https://github.com/$($tool.Repo)/releases"
    if (Read-YesNo "Pin $Section to $NewVersion?") {
        Set-IniValue -Section $Section -Key 'ReleaseTag' -Value $NewTag
        Set-IniValue -Section $Section -Key 'Version' -Value $NewVersion
        Set-IniValue -Section $Section -Key 'Sha256' -Value $hash
        Write-Ok "$Section pinned to $NewVersion."
        Write-Log "PINNED $Section $NewVersion $hash"
    }
}

function Update-AllPins {
    Write-Title 'Update pinned tool versions'
    Write-Info 'Checks GitHub for newer versions. Each change is shown with its hash and needs your Y.'
    if (-not (Assert-Online)) { return }
    $ini = Read-Ini
    foreach ($s in 'WinUtil', 'Win11Debloat') {
        try {
            $tag = (Get-GitHubJson "https://api.github.com/repos/$($ini[$s].Repo)/releases/latest").tag_name
            Update-PinnedTool -Section $s -NewTag $tag -NewVersion $tag
        }
        catch { Write-Bad "$s check failed: $($_.Exception.Message)" }
    }
    try {
        $repo = $ini['SophiaWin11'].Repo
        $tag = (Get-GitHubJson "https://api.github.com/repos/$repo/releases/latest").tag_name
        $versions = Get-GitHubJson "https://raw.githubusercontent.com/$repo/$tag/Sophia_Script_Releases.json"
        Update-PinnedTool -Section 'SophiaWin11' -NewTag $tag -NewVersion $versions.Sophia_Script_Windows_11
        Update-PinnedTool -Section 'SophiaWin10' -NewTag $tag -NewVersion $versions.Sophia_Script_Windows_10
    }
    catch { Write-Bad "Sophia check failed: $($_.Exception.Message)" }
    try {
        $sha = (Get-GitHubJson "https://api.github.com/repos/$($ini['RemoveWindowsAI'].Repo)/commits/main").sha
        Update-PinnedTool -Section 'RemoveWindowsAI' -NewTag $sha -NewVersion $sha
    }
    catch { Write-Bad "RemoveWindowsAI check failed: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- main

function Show-MainMenu {
    $os = $script:Os
    Write-Title 'WinOptSuite - Windows optimization launcher'
    Write-Info "  This PC: $($os.Name) $($os.Display) (build $($os.Build).$($os.UBR), $($os.Edition))"
    Write-Info ''
    $items = @(
        @('1', 'Quick Safe Optimize   (recommended)', 'Win11Debloat'),
        @('2', 'Debloat apps & telemetry      - Win11Debloat', 'Win11Debloat'),
        @('3', 'Full tweak toolbox (GUI)      - Chris Titus WinUtil', 'WinUtil'),
        @('4', 'Advanced fine-tuning          - Sophia Script', 'Sophia'),
        @('5', 'Remove Windows AI (Copilot/Recall) - RemoveWindowsAI', 'RemoveWindowsAI'),
        @('6', 'Privacy script generator (web) - privacy.sexy', 'privacy'),
        @('7', 'Maintenance: disk cleanup, SFC, DISM, temp files', 'builtin'),
        @('8', 'Restore / Undo', 'builtin'),
        @('9', 'Update pinned tool versions', 'builtin')
    )
    foreach ($i in $items) {
        $reason = if ($i[2] -in 'builtin', 'privacy') { $null } else { Get-BlockReason $i[2] }
        if ($reason) { Write-Host (" [{0}] {1}  (not available on this PC)" -f $i[0], $i[1]) -ForegroundColor DarkGray }
        else { Write-Host (" [{0}] {1}" -f $i[0], $i[1]) }
    }
    Write-Info ' [L] Open logs folder'
    Write-Info ' [Q] Quit'
}

function Start-Menu {
    while ($true) {
        Show-MainMenu
        $choice = (Read-Host 'Choose an option').Trim().ToUpper()
        Write-Log "Menu choice: $choice"
        try {
            switch ($choice) {
                '1' { Invoke-QuickSafe; Wait-Enter }
                '2' { $null = Invoke-Win11Debloat; Wait-Enter }
                '3' { Invoke-WinUtil; Wait-Enter }
                '4' { Invoke-Sophia; Wait-Enter }
                '5' { Invoke-RemoveWindowsAI; Wait-Enter }
                '6' { Open-PrivacySexy; Wait-Enter }
                '7' { Invoke-Maintenance; Wait-Enter }
                '8' { Show-RestoreMenu }
                '9' { Update-AllPins; Wait-Enter }
                'L' { Start-Process explorer.exe $script:LogsDir }
                'Q' { return }
                default { Write-Warn 'Please type one of the options shown.' }
            }
        }
        catch {
            Write-Bad "Something went wrong: $($_.Exception.Message)"
            Write-Bad "Details are in the log: $script:ActionLog"
            Write-Log "ERROR: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
            Wait-Enter
        }
    }
}

# ---------------------------------------------------------------- entry point

if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Bad 'WinOptSuite must run in Windows PowerShell 5.1 (powershell.exe), not PowerShell 7.'
    Write-Bad 'Start it by double-clicking WinOptSuite.bat.'
    exit 1
}

# Windows PowerShell 5.1 may default to old TLS versions that GitHub rejects.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

foreach ($d in $script:ToolsDir, $script:BackupsDir, $script:LogsDir) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:ActionLog = Join-Path $script:LogsDir "$stamp-actions.log"
$script:Os = Get-OsInfo

if ($SelfTest) {
    $ini = Read-Ini
    "OS: $($script:Os.Name) $($script:Os.Display) build $($script:Os.Build) edition $($script:Os.Edition)"
    foreach ($s in 'WinUtil', 'Win11Debloat', 'SophiaWin11', 'SophiaWin10', 'RemoveWindowsAI') {
        if (-not $ini.Contains($s)) { throw "config.ini is missing [$s]" }
        foreach ($k in 'Repo', 'ReleaseTag', 'Version', 'UrlTemplate', 'File') { if (-not $ini[$s][$k]) { throw "[$s] is missing $k" } }
        "  [$s] $($ini[$s].Version) -> $(Get-ToolUrl $ini[$s])"
    }
    foreach ($k in 'Win11Debloat', 'WinUtil', 'Sophia', 'RemoveWindowsAI') {
        $r = Get-BlockReason $k
        "  $k : $(if ($r) { "blocked - $r" } else { 'available' })"
    }
    exit 0
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Bad 'Administrator rights are required. Start WinOptSuite by double-clicking WinOptSuite.bat.'
    exit 1
}

Start-Transcript -Path (Join-Path $script:LogsDir "$stamp-transcript.log") -Append | Out-Null
Write-Log "WinOptSuite started on $($script:Os.Name) build $($script:Os.Build).$($script:Os.UBR) $($script:Os.Edition)"
try {
    if (-not (Test-Internet)) {
        Write-Warn 'You appear to be offline. Options that download a tool will not work until you connect.'
    }
    Start-Menu
}
finally {
    Write-Log 'WinOptSuite closed'
    Stop-Transcript | Out-Null
}
