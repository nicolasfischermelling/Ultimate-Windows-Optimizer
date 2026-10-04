<#
.SYNOPSIS
    Ultimate Windows Optimizer - full-auto cleanup and performance tuning for Windows 10/11.

.DESCRIPTION
    Runs end to end without per-step prompts:
      1. Creates a System Restore point.
      2. Cleanup pass: temp folders, Recycle Bin, Windows Update cache, Delivery Optimization,
         browser caches (Chrome/Edge/Brave, skipped if running), Disk Cleanup categories,
         Windows.old above a size threshold.
      3. Performance pass: power plan, low-value startup apps, visual effects, background
         Store apps, optional services (Fax, Spooler without printers, Xbox on non-gaming PCs),
         drive optimization (TRIM/defrag).
      4. Bloatware audit: report only, nothing is uninstalled.
    Every registry/service/power-plan change is journaled so Undo.ps1 can revert it.

.PARAMETER DryRun
    Show what would be done without changing anything.

.PARAMETER Mode
    All (default), Cleanup, Performance or Drives (drive optimization only).

.PARAMETER VisualEffects
    BestPerformance (default, keeps font smoothing) or Skip.

.PARAMETER Gaming
    Auto (default, detects game launchers), Yes or No. Controls whether Xbox services are disabled.

.PARAMETER WindowsOldMinGB
    Windows.old is removed only when at least this large. Default 2.

.PARAMETER SkipRestorePoint
    Do not create a System Restore point.

.EXAMPLE
    .\Optimize.ps1 -DryRun
.EXAMPLE
    .\Optimize.ps1 -Mode Cleanup
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [ValidateSet('All', 'Cleanup', 'Performance', 'Drives')][string]$Mode = 'All',
    [ValidateSet('BestPerformance', 'Skip')][string]$VisualEffects = 'BestPerformance',
    [ValidateSet('Auto', 'Yes', 'No')][string]$Gaming = 'Auto',
    [ValidateRange(0, 1000)][int]$WindowsOldMinGB = 2,
    [switch]$SkipRestorePoint
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'src\Common.ps1')
. (Join-Path $PSScriptRoot 'src\Cleanup.ps1')
. (Join-Path $PSScriptRoot 'src\Performance.ps1')
. (Join-Path $PSScriptRoot 'src\Audit.ps1')

$script:DryRun = [bool]$DryRun
$script:VisualEffects = $VisualEffects
$script:Gaming = $Gaming
$script:WindowsOldMinGB = $WindowsOldMinGB
$script:Lists = Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot 'config\Lists.psd1')
$script:Journal = [System.Collections.Generic.List[object]]::new()
$script:ErrorCount = 0

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logDir = Join-Path $PSScriptRoot 'logs'
$null = New-Item -ItemType Directory -Path $logDir -Force
$script:LogFile = Join-Path $logDir "optimize-$stamp.log"
$script:JournalFile = Join-Path $logDir "journal-$stamp.json"
$reportFile = Join-Path $logDir "report-$stamp.json"

$script:Report = [ordered]@{
    StartedAt              = (Get-Date).ToString('s')
    Computer               = $env:COMPUTERNAME
    DryRun                 = $DryRun.IsPresent
    Mode                   = $Mode
    FreeBeforeBytes        = $null
    FreeAfterBytes         = $null
    Cleanup                = [System.Collections.Generic.List[object]]::new()
    PowerPlan              = 'not run'
    StartupDisabled        = [System.Collections.Generic.List[string]]::new()
    VisualEffects          = 'not run'
    BackgroundAppsDisabled = [System.Collections.Generic.List[string]]::new()
    ServicesChanged        = [System.Collections.Generic.List[string]]::new()
    DrivesOptimized        = [System.Collections.Generic.List[object]]::new()
    Flagged                = [System.Collections.Generic.List[object]]::new()
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $script:DryRun) {
    Write-Log 'Administrator rights required. Right-click Run-Optimizer.cmd or start PowerShell as Administrator.' 'ERROR'
    exit 1
}

function New-SafetyRestorePoint {
    if ($SkipRestorePoint -or $script:DryRun) { return }
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description 'Ultimate Windows Optimizer' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningVariable rpWarn -WarningAction SilentlyContinue
        if ($rpWarn) { Write-Log "Restore point: $rpWarn" 'WARN' } else { Write-Log 'Restore point created' 'OK' }
    }
    catch {
        Write-Log "Restore point not created ($($_.Exception.Message)). Continuing; Undo.ps1 can still revert tracked changes." 'WARN'
    }
}

function Write-Summary {
    $r = $script:Report
    $freed = $r.FreeAfterBytes - $r.FreeBeforeBytes
    Write-Host ''
    Write-Host '================ SUMMARY ================' -ForegroundColor White
    if ($script:DryRun) { Write-Host '(dry-run: nothing was changed)' -ForegroundColor Cyan }
    Write-Host ("Disk ({0}) free: {1} -> {2}  (freed {3})" -f $env:SystemDrive, (Format-Bytes $r.FreeBeforeBytes), (Format-Bytes $r.FreeAfterBytes), (Format-Bytes ([math]::Max(0, $freed))))
    Write-Host ("Startup items disabled: {0}{1}" -f $r.StartupDisabled.Count, $(if ($r.StartupDisabled.Count) { ' - ' + ($r.StartupDisabled -join ', ') } else { '' }))
    Write-Host "Power plan: $($r.PowerPlan)"
    Write-Host "Visual effects: $($r.VisualEffects)"
    if ($r.BackgroundAppsDisabled.Count) { Write-Host "Background apps disabled: $($r.BackgroundAppsDisabled -join ', ')" }
    if ($r.ServicesChanged.Count) { Write-Host "Services changed: $($r.ServicesChanged -join ', ')" }
    if ($r.DrivesOptimized.Count) { Write-Host "Drives optimized: $(($r.DrivesOptimized | ForEach-Object { "$($_.Drive) $($_.Media)" }) -join ', ')" }
    if ($r.Flagged.Count) {
        Write-Host ''
        Write-Host 'Flagged, NOT changed (decide separately):' -ForegroundColor Yellow
        $r.Flagged | Sort-Object Category, Item | ForEach-Object { Write-Host ("  [{0}] {1} - {2}" -f $_.Category, $_.Item, $_.Reason) }
    }
    Write-Host ''
    Write-Host "Report:  $reportFile"
    Write-Host "Log:     $script:LogFile"
    if (Test-Path -LiteralPath $script:JournalFile) { Write-Host "Undo:    .\Undo.ps1 -JournalPath `"$script:JournalFile`"" }
    Write-Host 'Sign out or restart to apply visual-effect and service changes.'
    if ($script:ErrorCount) { Write-Host "$($script:ErrorCount) step(s) reported errors - see the log." -ForegroundColor Red }
}

Write-Log "Ultimate Windows Optimizer - mode: $Mode, dry-run: $($script:DryRun)"
$script:Report.FreeBeforeBytes = Get-SystemDriveFreeBytes
try {
    New-SafetyRestorePoint
    if ($Mode -in 'All', 'Cleanup') { Invoke-CleanupPass }
    if ($Mode -in 'All', 'Performance') { Invoke-PerformancePass }
    if ($Mode -eq 'Drives') { Invoke-Section 'Optimize-Drives' }
    if ($Mode -ne 'Drives') { Invoke-Section 'Find-Bloatware' }
}
finally {
    Save-Journal
    $script:Report.FreeAfterBytes = Get-SystemDriveFreeBytes
    $script:Report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportFile -Encoding UTF8
}
Write-Summary
if ($script:ErrorCount) { exit 2 }
