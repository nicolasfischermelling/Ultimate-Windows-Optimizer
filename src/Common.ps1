# Shared helpers: logging, dry-run wrapper, change journal, reporting.
# Dot-sourced by Optimize.ps1; relies on script-scope state set there.

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'DRY')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = switch ($Level) {
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'OK'    { 'Green' }
        'DRY'   { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
}

# Runs $Action unless in dry-run mode. Returns $true on success, $false otherwise.
function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    if ($script:DryRun) {
        Write-Log "[dry-run] $Description" 'DRY'
        return $false
    }
    try {
        $null = & $Action
        Write-Log $Description 'OK'
        return $true
    }
    catch {
        Write-Log "$Description failed: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

function Get-SystemDriveFreeBytes {
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    return [double]$disk.FreeSpace
}

function Test-AnyMatch {
    param([string]$Text, [string[]]$Patterns)
    foreach ($pattern in $Patterns) {
        if ($Text -match $pattern) { return $true }
    }
    return $false
}

function Add-Flag {
    param([string]$Category, [string]$Item, [string]$Reason)
    $script:Report.Flagged.Add([pscustomobject]@{ Category = $Category; Item = $Item; Reason = $Reason })
}

function Get-InstalledPrograms {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } |
        Select-Object DisplayName, Publisher -Unique
}

# Writes a registry value and records the previous state so Undo.ps1 can revert it.
function Set-TrackedRegistryValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][Microsoft.Win32.RegistryValueKind]$Kind
    )
    $entry = [ordered]@{ Type = 'Registry'; Path = $Path; Name = $Name; Existed = $false; OldValue = $null; OldKind = $null }
    if (Test-Path -LiteralPath $Path) {
        $key = Get-Item -LiteralPath $Path
        if ($key.GetValueNames() -contains $Name) {
            $entry.Existed = $true
            $entry.OldValue = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
            $entry.OldKind = $key.GetValueKind($Name).ToString()
        }
    }
    return (Invoke-Step "Registry: $Path\$Name" {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Kind -Force | Out-Null
        $script:Journal.Add([pscustomobject]$entry)
    })
}

# Changes a service start type and records the previous one.
function Set-TrackedServiceStartType {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Manual', 'Disabled')][string]$StartType
    )
    $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if (-not $cim) { return $false }
    $old = switch ($cim.StartMode) { 'Auto' { 'Automatic' } default { $cim.StartMode } }
    if ($old -eq $StartType) { return $false }
    if ($old -in @('Boot', 'System')) { return $false }

    $entry = [pscustomobject]@{ Type = 'Service'; Name = $Name; OldStartType = $old; DelayedAutoStart = [bool]($cim.PSObject.Properties['DelayedAutoStart'] -and $cim.DelayedAutoStart) }
    $ok = Invoke-Step "Service $Name : $old -> $StartType" {
        if ($StartType -eq 'Disabled' -and $cim.State -eq 'Running') { Stop-Service -Name $Name -Force -ErrorAction Stop }
        Set-Service -Name $Name -StartupType $StartType -ErrorAction Stop
        $script:Journal.Add($entry)
    }
    if ($ok) { $script:Report.ServicesChanged.Add("$Name ($old -> $StartType)") }
    return $ok
}

function Save-Journal {
    if ($script:DryRun -or $script:Journal.Count -eq 0) { return }
    ConvertTo-Json -InputObject @($script:Journal) -Depth 5 |
        Set-Content -LiteralPath $script:JournalFile -Encoding UTF8
}
