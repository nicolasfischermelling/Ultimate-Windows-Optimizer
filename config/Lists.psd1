# Pattern lists (case-insensitive regex) driving the optimizer. Edit to taste.
@{
    # Startup entries matching these are always left enabled (wins over StartupDisable).
    StartupKeep = @(
        'SecurityHealth', 'Windows Defender', 'MsMpEng',
        'Avast', 'AVG', 'Norton', 'McAfee', 'Kaspersky', 'Bitdefender', 'ESET', 'egui', 'Malwarebytes', 'Sophos', 'Webroot', 'Trend ?Micro',
        'Realtek', 'RtkAud', 'Nahimic', 'Dolby', 'Waves', 'MaxxAudio',
        'NVIDIA', 'nvcpl', 'AMD', 'Radeon', 'igfx', 'Intel',
        'Synaptics', 'ELAN', 'ETD', 'Logi', 'Razer', 'iCUE', 'Corsair', 'SteelSeries', 'Wacom', 'Bluetooth',
        'OneDrive', 'GoogleDriveFS', 'Dropbox', 'Backup', 'VPN'
    )

    # Low-value startup entries disabled automatically.
    StartupDisable = @(
        'Spotify', 'Discord', 'Steam', 'EpicGamesLauncher', 'Battle\.net', 'EADesktop', '\bOrigin\b', 'GalaxyClient', 'Ubisoft', 'upc\.exe',
        'Teams', 'ms-teams', 'Skype', 'Zoom', 'Slack', 'WhatsApp', 'Telegram',
        'MicrosoftEdgeAutoLaunch', 'Opera Browser Assistant', 'BraveSoftware.*--no-startup-window',
        'CCleaner', 'iTunesHelper', 'AdobeGCInvoker', 'Adobe Creative Cloud', 'AcroTray', 'Acrobat Synchronizer',
        'uTorrent', 'BitTorrent', 'Cortana', 'GoogleUpdate', 'CiscoMeetingDaemon', 'Webex', 'LGHUB'
    )

    # Store apps whose background activity is disabled (matched against the package name).
    BackgroundAppsDisable = @(
        'Microsoft\.BingNews', 'Microsoft\.BingWeather', 'Microsoft\.BingSearch', 'Microsoft\.GetHelp', 'Microsoft\.Getstarted',
        'Microsoft\.MicrosoftSolitaireCollection', 'Microsoft\.ZuneMusic', 'Microsoft\.ZuneVideo', 'Microsoft\.People',
        'Microsoft\.MicrosoftOfficeHub', 'Microsoft\.549981C3F5F10', 'Clipchamp', 'Microsoft\.GamingApp', 'Microsoft\.XboxApp',
        'Microsoft\.Xbox\.TCUI', 'Microsoft\.XboxGamingOverlay', 'Microsoft\.MixedReality', 'Microsoft\.Microsoft3DViewer',
        'Microsoft\.WindowsFeedbackHub', 'Microsoft\.WindowsMaps'
    )

    # Disk Cleanup (cleanmgr) categories. Downloads folder is deliberately excluded.
    # 'Previous Installations' (Windows.old) is added automatically above the size threshold.
    DiskCleanupCategories = @(
        'Temporary Files', 'Recycle Bin', 'Thumbnail Cache', 'Delivery Optimization Files', 'Update Cleanup',
        'Temporary Setup Files', 'Windows Error Reporting Files', 'Downloaded Program Files', 'Internet Cache Files',
        'Old ChkDsk Files', 'Setup Log Files', 'System error memory dump files', 'System error minidump files',
        'Windows Upgrade Log Files'
    )

    # Installed game launchers; if any is found the PC is treated as a gaming PC.
    GameLaunchers = @('^Steam$', 'Epic Games Launcher', 'Battle\.net', '^EA app$', 'Ubisoft Connect', 'GOG GALAXY', 'Riot', 'Xbox')

    XboxServices = @('XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc')

    # Printers that do not count as physical (Spooler is only disabled when none other exist).
    VirtualPrinterPatterns = @('Microsoft Print to PDF', 'Microsoft XPS', 'OneNote', '^Fax', 'Send To', 'PORTPROMPT:', 'SHRFAX:', 'nul:')

    BloatwareAppx = @(
        'CandyCrush', 'king\.com', 'Disney', 'TikTok', 'Facebook', 'Instagram', 'Twitter', 'Netflix', 'Spotify', 'Amazon',
        'BytedancePte', 'Clipchamp', 'Microsoft\.BingNews', 'Microsoft\.BingWeather', 'Microsoft\.GetHelp', 'Microsoft\.Getstarted',
        'Microsoft\.MicrosoftSolitaireCollection', 'Microsoft\.ZuneMusic', 'Microsoft\.ZuneVideo', 'Microsoft\.MixedReality',
        'Microsoft\.Microsoft3DViewer', 'Microsoft\.MicrosoftOfficeHub', 'Microsoft\.SkypeApp', 'Microsoft\.People', 'Microsoft\.WindowsFeedbackHub'
    )

    BloatwareWin32 = @(
        'McAfee', 'Norton', 'WildTangent', 'Booking\.com', 'ExpressVPN', 'CyberLink', 'Driver Booster', 'Driver Easy',
        'PC Cleaner', 'Advanced SystemCare', 'Reimage', 'Restoro', 'CCleaner', 'Avast Cleanup', 'AVG TuneUp',
        'HP Wolf', 'HP Support Assistant', 'Dell SupportAssist', 'Lenovo Vantage', 'MyASUS', 'Acer Care Center'
    )
}
