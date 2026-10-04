<#
.SYNOPSIS
    Reverts the registry, service and power-plan changes recorded by Optimize.ps1.

.PARAMETER JournalPath
    Journal file to revert. Defaults to the most recent logs\journal-*.json.

.NOTES
    Deleted files (temp, caches, Windows.old) cannot be restored. For a full system
    rollback use the "Ultimate Windows Optimizer" System Restore point.
#>
[CmdletBinding()]
param([string]$JournalPath)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'Run as Administrator.' -ForegroundColor Red; exit 1 }

if (-not $JournalPath) {
    $latest = Get-ChildItem -Path (Join-Path $PSScriptRoot 'logs') -Filter 'journal-*.json' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $latest) { Write-Host 'No journal found in logs\.' -ForegroundColor Yellow; exit 1 }
    $JournalPath = $latest.FullName
}
Write-Host "Reverting changes from $JournalPath"

$entries = @(Get-Content -LiteralPath $JournalPath -Raw | ConvertFrom-Json | ForEach-Object { $_ })
[array]::Reverse($entries)

$ok = 0; $failed = 0
foreach ($e in $entries) {
    try {
        switch ($e.Type) {
            'Registry' {
                if ($e.Existed) {
                    $value = switch ($e.OldKind) {
                        'Binary'      { [byte[]]@($e.OldValue) }
                        'MultiString' { [string[]]@($e.OldValue) }
                        'DWord'       { [int]$e.OldValue }
                        'QWord'       { [long]$e.OldValue }
                        default       { [string]$e.OldValue }
                    }
                    New-ItemProperty -LiteralPath $e.Path -Name $e.Name -Value $value -PropertyType $e.OldKind -Force -ErrorAction Stop | Out-Null
                }
                else {
                    Remove-ItemProperty -LiteralPath $e.Path -Name $e.Name -ErrorAction SilentlyContinue
                }
                Write-Host "Registry restored: $($e.Path)\$($e.Name)"
            }
            'Service' {
                if ($e.OldStartType -eq 'Automatic' -and $e.DelayedAutoStart) {
                    sc.exe config $e.Name start= delayed-auto | Out-Null
                }
                else {
                    Set-Service -Name $e.Name -StartupType $e.OldStartType -ErrorAction Stop
                }
                if ($e.OldStartType -in 'Automatic') { Start-Service -Name $e.Name -ErrorAction SilentlyContinue }
                Write-Host "Service restored: $($e.Name) -> $($e.OldStartType)"
            }
            'PowerPlan' {
                if ($e.OldGuid) {
                    powercfg /setactive $e.OldGuid
                    Write-Host "Power plan restored: $($e.OldGuid)"
                }
            }
        }
        $ok++
    }
    catch {
        $failed++
        Write-Host "Failed to revert $($e.Type) $($e.Name): $($_.Exception.Message)" -ForegroundColor Red
    }
}
Write-Host "Done. Reverted: $ok, failed: $failed. Sign out or restart to apply."
