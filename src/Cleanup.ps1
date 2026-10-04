# Cleanup pass: temp files, Recycle Bin, Windows Update cache, Delivery Optimization,
# browser caches and Disk Cleanup (cleanmgr) categories.

function Remove-FolderContents {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $size = Get-FolderBytes -Path $Path
    # Locked files are skipped silently; the real result is measured as free-space delta.
    $ok = Invoke-Step "Clean $Label ($(Format-Bytes $size) found)" {
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:Report.Cleanup.Add([pscustomobject]@{ Item = $Label; FoundBytes = $size; Done = $ok })
}

function Clear-TempFolders {
    Remove-FolderContents -Path $env:TEMP -Label 'User temp'
    Remove-FolderContents -Path (Join-Path $env:windir 'Temp') -Label 'Windows temp'
}

function Clear-RecycleBins {
    $ok = Invoke-Step 'Empty Recycle Bin' { Clear-RecycleBin -Force -ErrorAction SilentlyContinue }
    $script:Report.Cleanup.Add([pscustomobject]@{ Item = 'Recycle Bin'; FoundBytes = $null; Done = $ok })
}

function Clear-WindowsUpdateCache {
    $running = @(Get-Service -Name 'wuauserv', 'bits' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running')
    if (-not $script:DryRun) { $running | Stop-Service -Force -ErrorAction SilentlyContinue }
    try {
        Remove-FolderContents -Path (Join-Path $env:windir 'SoftwareDistribution\Download') -Label 'Windows Update download cache'
    }
    finally {
        if (-not $script:DryRun) { $running | Start-Service -ErrorAction SilentlyContinue }
    }
}

function Clear-DeliveryOptimization {
    if (-not (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue)) { return }
    $ok = Invoke-Step 'Clear Delivery Optimization cache' { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop }
    $script:Report.Cleanup.Add([pscustomobject]@{ Item = 'Delivery Optimization cache'; FoundBytes = $null; Done = $ok })
}

function Clear-BrowserCaches {
    $browsers = @(
        @{ Name = 'Chrome'; Process = 'chrome'; Root = "$env:LOCALAPPDATA\Google\Chrome\User Data" },
        @{ Name = 'Edge'; Process = 'msedge'; Root = "$env:LOCALAPPDATA\Microsoft\Edge\User Data" },
        @{ Name = 'Brave'; Process = 'brave'; Root = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data" }
    )
    foreach ($b in $browsers) {
        if (-not (Test-Path -LiteralPath $b.Root)) { continue }
        if (Get-Process -Name $b.Process -ErrorAction SilentlyContinue) {
            Add-Flag 'Cleanup' "$($b.Name) cache" 'Browser was running; cache skipped. Close it fully and re-run with -Mode Cleanup.'
            continue
        }
        $profiles = Get-ChildItem -LiteralPath $b.Root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' }
        foreach ($p in $profiles) {
            foreach ($sub in 'Cache', 'Code Cache', 'GPUCache') {
                Remove-FolderContents -Path (Join-Path $p.FullName $sub) -Label "$($b.Name) [$($p.Name)] $sub"
            }
        }
    }
}

function Invoke-DiskCleanup {
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    $flag = 'StateFlags0777'
    $categories = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $script:Lists.DiskCleanupCategories) { $categories.Add($c) }

    $winOld = Join-Path $env:SystemDrive 'Windows.old'
    if (Test-Path -LiteralPath $winOld) {
        $size = Get-FolderBytes -Path $winOld
        if ($size -ge ($script:WindowsOldMinGB * 1GB)) {
            $categories.Add('Previous Installations')
            Write-Log "Windows.old is $(Format-Bytes $size); it will be removed (rollback to the previous Windows version will no longer be possible)." 'WARN'
        }
        else {
            Add-Flag 'Cleanup' 'Windows.old' "Present ($(Format-Bytes $size)) but below the $($script:WindowsOldMinGB) GB threshold; kept."
        }
    }

    $present = @($categories | Where-Object { Test-Path -LiteralPath (Join-Path $root $_) })
    if ($present.Count -eq 0) { return }

    $ok = Invoke-Step "Disk Cleanup: $($present -join ', ')" {
        foreach ($c in $present) {
            New-ItemProperty -LiteralPath (Join-Path $root $c) -Name $flag -Value 2 -PropertyType DWord -Force | Out-Null
        }
        try {
            $proc = Start-Process -FilePath "$env:windir\System32\cleanmgr.exe" -ArgumentList '/sagerun:777' -PassThru -WindowStyle Hidden
            if (-not $proc.WaitForExit(45 * 60 * 1000)) { throw 'cleanmgr did not finish within 45 minutes' }
        }
        finally {
            foreach ($c in $present) {
                Remove-ItemProperty -LiteralPath (Join-Path $root $c) -Name $flag -ErrorAction SilentlyContinue
            }
        }
    }
    $script:Report.Cleanup.Add([pscustomobject]@{ Item = 'Disk Cleanup (cleanmgr)'; FoundBytes = $null; Done = $ok })
}

function Invoke-CleanupPass {
    Write-Log '=== Cleanup pass ==='
    foreach ($step in 'Clear-TempFolders', 'Clear-RecycleBins', 'Clear-WindowsUpdateCache',
        'Clear-DeliveryOptimization', 'Clear-BrowserCaches', 'Invoke-DiskCleanup') {
        Invoke-Section $step
    }
}
