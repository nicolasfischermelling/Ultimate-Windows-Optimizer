# Audit pass: flags bloatware candidates. Never uninstalls anything.

function Find-Bloatware {
    Write-Log '=== Bloatware audit (report only) ==='
    Get-AppxPackage -ErrorAction SilentlyContinue |
        Where-Object { Test-AnyMatch $_.Name $script:Lists.BloatwareAppx } |
        Sort-Object Name -Unique |
        ForEach-Object { Add-Flag 'Bloatware' $_.Name 'Store app candidate for removal; not uninstalled.' }

    Get-InstalledPrograms |
        Where-Object { Test-AnyMatch $_.DisplayName $script:Lists.BloatwareWin32 } |
        ForEach-Object { Add-Flag 'Bloatware' $_.DisplayName 'Desktop program candidate for removal; not uninstalled.' }
}
