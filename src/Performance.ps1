# Performance pass: power plan, startup apps, visual effects, drive optimization,
# background apps and optional services.

$script:HighPerformanceGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$script:BalancedGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'
$script:GuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

function Get-ActivePowerSchemeGuid {
    $out = powercfg /getactivescheme
    if ("$out" -match $script:GuidPattern) { return $Matches[0].ToLower() }
    return $null
}

function Set-PowerPlan {
    $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    # Win32_Battery.BatteryStatus 1 = discharging (running on battery).
    $onBattery = $battery -and $battery.BatteryStatus -eq 1
    $targetName = if ($onBattery) { 'Balanced' } else { 'High performance' }
    $target = if ($onBattery) { $script:BalancedGuid } else { $script:HighPerformanceGuid }

    $current = Get-ActivePowerSchemeGuid
    if ($current -eq $target) {
        $script:Report.PowerPlan = "$targetName (already active)"
        return
    }

    if (-not $onBattery -and -not ((powercfg /list) -match $target)) {
        # Some OEM images hide High performance; restore it from the built-in template.
        if ($script:DryRun) {
            Write-Log '[dry-run] Recreate High performance plan from template' 'DRY'
        }
        else {
            $dup = powercfg -duplicatescheme $script:HighPerformanceGuid 2>$null
            if ("$dup" -match $script:GuidPattern) { $target = $Matches[0].ToLower() }
            else {
                Add-Flag 'Power' 'High performance plan' 'Not available on this device (likely Modern Standby); power plan left unchanged.'
                $script:Report.PowerPlan = 'unchanged'
                return
            }
        }
    }

    $ok = Invoke-Step "Power plan -> $targetName" {
        powercfg /setactive $target
        if ($LASTEXITCODE -ne 0) { throw "powercfg exited with $LASTEXITCODE" }
        $script:Journal.Add([pscustomobject]@{ Type = 'PowerPlan'; OldGuid = $current })
    }
    $script:Report.PowerPlan = if ($ok) { $targetName } elseif ($script:DryRun) { "$targetName (dry-run)" } else { 'unchanged (error)' }
    if ($battery) { Add-Flag 'Power' 'Laptop detected' "Plan chosen: $targetName (on battery: $onBattery)." }
}

function Get-StartupEntries {
    $entries = [System.Collections.Generic.List[object]]::new()
    $runKeys = @(
        @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
        @{ Run = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
        @{ Run = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
    )
    foreach ($k in $runKeys) {
        if (-not (Test-Path -LiteralPath $k.Run)) { continue }
        $key = Get-Item -LiteralPath $k.Run
        foreach ($name in $key.GetValueNames()) {
            if (-not $name) { continue }
            $entries.Add([pscustomobject]@{ Name = $name; Command = [string]$key.GetValue($name); Approved = $k.Approved })
        }
    }
    $folders = @(
        @{ Path = [Environment]::GetFolderPath('Startup'); Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' },
        @{ Path = [Environment]::GetFolderPath('CommonStartup'); Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
    )
    foreach ($f in $folders) {
        if (-not $f.Path -or -not (Test-Path -LiteralPath $f.Path)) { continue }
        Get-ChildItem -LiteralPath $f.Path -File -ErrorAction SilentlyContinue |
            Where-Object Name -ne 'desktop.ini' |
            ForEach-Object { $entries.Add([pscustomobject]@{ Name = $_.Name; Command = $_.FullName; Approved = $f.Approved }) }
    }
    return $entries
}

function Test-StartupEntryDisabled {
    param($Entry)
    if (-not (Test-Path -LiteralPath $Entry.Approved)) { return $false }
    $value = (Get-Item -LiteralPath $Entry.Approved).GetValue($Entry.Name)
    # StartupApproved: first byte with the low bit set (0x03, 0x07...) means disabled.
    return ($value -is [byte[]] -and $value.Length -gt 0 -and ($value[0] -band 1) -eq 1)
}

function Optimize-StartupApps {
    foreach ($e in Get-StartupEntries) {
        if (Test-StartupEntryDisabled $e) { continue }
        $text = "$($e.Name) $($e.Command)"
        if (Test-AnyMatch $text $script:Lists.StartupKeep) { continue }
        if (Test-AnyMatch $text $script:Lists.StartupDisable) {
            # Same format Task Manager writes: 0x03 + 3 zero bytes + FILETIME.
            $value = [byte[]](@(3, 0, 0, 0) + [BitConverter]::GetBytes((Get-Date).ToFileTime()))
            if (Set-TrackedRegistryValue -Path $e.Approved -Name $e.Name -Value $value -Kind Binary) {
                $script:Report.StartupDisabled.Add($e.Name)
            }
            elseif ($script:DryRun) {
                $script:Report.StartupDisabled.Add("$($e.Name) (dry-run)")
            }
        }
        else {
            Add-Flag 'Startup' $e.Name 'Not on the known lists; left enabled for manual review.'
        }
    }
}

function Set-VisualEffects {
    if ($script:VisualEffects -eq 'Skip') {
        $script:Report.VisualEffects = 'skipped'
        return
    }
    $desktop = 'HKCU:\Control Panel\Desktop'
    # "Adjust for best performance" mask, but keep font smoothing (ClearType) for readability.
    $null = Set-TrackedRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting' -Value 3 -Kind DWord
    $null = Set-TrackedRegistryValue -Path $desktop -Name 'UserPreferencesMask' -Value ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)) -Kind Binary
    $null = Set-TrackedRegistryValue -Path $desktop -Name 'FontSmoothing' -Value '2' -Kind String
    $null = Set-TrackedRegistryValue -Path "$desktop\WindowMetrics" -Name 'MinAnimate' -Value '0' -Kind String
    $null = Set-TrackedRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarAnimations' -Value 0 -Kind DWord
    $script:Report.VisualEffects = 'best performance (font smoothing kept); applies after sign-out'
}

function Optimize-Drives {
    $volumes = Get-Volume -ErrorAction SilentlyContinue | Where-Object {
        $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and ("$($_.FileSystemType)$($_.FileSystem)" -match 'NTFS|ReFS')
    }
    foreach ($v in $volumes) {
        $letter = [string]$v.DriveLetter
        $media = 'unknown'
        try {
            $diskNumber = (Get-Partition -DriveLetter $letter -ErrorAction Stop).DiskNumber
            $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$diskNumber } | Select-Object -First 1
            if ($pd) { $media = [string]$pd.MediaType }
        }
        catch { }
        # Optimize-Volume picks TRIM for SSDs and defrag for HDDs automatically.
        $ok = Invoke-Step "Optimize drive ${letter}: ($media)" { Optimize-Volume -DriveLetter $letter -ErrorAction Stop }
        $script:Report.DrivesOptimized.Add([pscustomobject]@{ Drive = "${letter}:"; Media = $media; Done = $ok })
    }
}

function Disable-BackgroundApps {
    $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'
    $packages = Get-AppxPackage -ErrorAction SilentlyContinue |
        Where-Object { Test-AnyMatch $_.Name $script:Lists.BackgroundAppsDisable } |
        Sort-Object PackageFamilyName -Unique
    foreach ($pkg in $packages) {
        $path = Join-Path $root $pkg.PackageFamilyName
        $a = Set-TrackedRegistryValue -Path $path -Name 'Disabled' -Value 1 -Kind DWord
        $b = Set-TrackedRegistryValue -Path $path -Name 'DisabledByUser' -Value 1 -Kind DWord
        if ($a -and $b) { $script:Report.BackgroundAppsDisabled.Add($pkg.Name) }
        elseif ($script:DryRun) { $script:Report.BackgroundAppsDisabled.Add("$($pkg.Name) (dry-run)") }
    }
}

function Test-IsGamingPc {
    switch ($script:Gaming) {
        'Yes' { return $true }
        'No' { return $false }
    }
    $launchers = Get-InstalledPrograms | Where-Object { Test-AnyMatch $_.DisplayName $script:Lists.GameLaunchers }
    return [bool]$launchers
}

function Get-PhysicalPrinters {
    Get-Printer -ErrorAction SilentlyContinue | Where-Object {
        -not (Test-AnyMatch "$($_.Name) $($_.DriverName) $($_.PortName)" $script:Lists.VirtualPrinterPatterns)
    }
}

function Optimize-Services {
    $null = Set-TrackedServiceStartType -Name 'Fax' -StartType Disabled

    if (Get-Command Get-Printer -ErrorAction SilentlyContinue) {
        if (@(Get-PhysicalPrinters).Count -eq 0) {
            if (Set-TrackedServiceStartType -Name 'Spooler' -StartType Disabled) {
                Add-Flag 'Services' 'Print Spooler' 'Disabled (no physical printer found). "Print to PDF" will not work until it is re-enabled or Undo.ps1 is run.'
            }
        }
    }

    if (Test-IsGamingPc) {
        Add-Flag 'Services' 'Xbox services' 'Game launcher detected (or -Gaming Yes); Xbox services left untouched.'
    }
    else {
        foreach ($svc in $script:Lists.XboxServices) { $null = Set-TrackedServiceStartType -Name $svc -StartType Disabled }
    }
}

function Invoke-PerformancePass {
    Write-Log '=== Performance pass ==='
    Set-PowerPlan
    Optimize-StartupApps
    Set-VisualEffects
    Disable-BackgroundApps
    Optimize-Services
    Optimize-Drives
}
