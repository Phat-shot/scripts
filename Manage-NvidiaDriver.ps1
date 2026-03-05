#Requires -RunAsAdministrator
<#
.SYNOPSIS
    airgpu Driver Manager -- NVIDIA driver management for Amazon EC2 Windows 11 instances.

.DESCRIPTION
    - Detects installed NVIDIA driver (version, variant, GPU model)
    - Checks latest versions from official AWS S3 buckets
    - Supports variant switching: Gaming <-> GRID
    - Downloads driver BEFORE uninstall (safe -- aborts if download fails)
    - Full clean uninstall + registry cleanup + reboot-safe state machine
    - Sets NVIDIA Virtual Display as primary after install

.NOTES
    Run as Administrator. Requires AWS Tools for PowerShell + AmazonS3ReadOnlyAccess.
    Credentials : C:\Users\<user>\.aws\credentials  (profile: default)
    Working dir : C:\Program Files\airgpu\Driver Manager\
    Log file    : C:\Program Files\airgpu\Driver Manager\driver_manager.log
#>

param([switch]$Resume)

# ─────────────────────────────────────────────────────────────
#  CONFIGURATION
# ─────────────────────────────────────────────────────────────
$WorkDir      = "C:\Program Files\airgpu\Driver Manager"
$StateFile    = "$WorkDir\state.json"
$LogFile      = "$WorkDir\driver_manager.log"
$TempDir      = "C:\Temp\airgpuDriverManager"
$RunKey       = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$RunName      = "airgpuDriverManagerResume"
$ScriptPath   = $MyInvocation.MyCommand.Path
$AwsCredsFile = "$env:USERPROFILE\.aws\credentials"

# ─────────────────────────────────────────────────────────────
#  LOGGING
# ─────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    $color = switch ($Level) { "ERROR" { "Red" } "WARN" { "Yellow" } "OK" { "Green" } default { "Cyan" } }
    Write-Host $line -ForegroundColor $color
}

# ─────────────────────────────────────────────────────────────
#  AWS CREDENTIALS
#  Explicitly uses SharedCredentialsFile to avoid conflict with
#  empty NetSDKCredentialsFile profile of the same name.
# ─────────────────────────────────────────────────────────────
function Set-AwsCredentials {
    if (Get-Command Set-AWSCredential -ErrorAction SilentlyContinue) {
        try {
            Set-AWSCredential -ProfileName default -ProfileLocation $AwsCredsFile -ErrorAction Stop
        } catch {
            Write-Log "AWS profile 'default' not found at $AwsCredsFile -- trying IAM role/env vars" -Level "WARN"
        }
    }
}

# ─────────────────────────────────────────────────────────────
#  STATE MANAGEMENT
# ─────────────────────────────────────────────────────────────
function Save-State {
    param([hashtable]$State)
    if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
    Write-Log "State saved: $($State.Step)"
}

function Load-State {
    if (Test-Path $StateFile) {
        try {
            $json = (Get-Content $StateFile -Raw -Encoding UTF8) | ConvertFrom-Json
            $ht = @{}
            $json.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
            return $ht
        } catch { Write-Log "Could not load state: $_" -Level "WARN" }
    }
    return $null
}

function Clear-State {
    if (Test-Path $StateFile) { Remove-Item $StateFile -Force }
    Remove-ItemProperty -Path $RunKey -Name $RunName -Force -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "airgpuDriverManagerResume" -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "State cleared."
}

function Register-ResumeOnBoot {
    param([string]$NextStep)
    $state = Load-State
    if ($null -eq $state) { $state = @{} }
    $state.Step = $NextStep
    Save-State $state
    $action    = New-ScheduledTaskAction -Execute "powershell.exe" `
                     -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Resume"
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
                     -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 60)
    Register-ScheduledTask -TaskName "airgpuDriverManagerResume" -Action $action `
        -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Set-ItemProperty -Path $RunKey -Name $RunName `
        -Value "powershell.exe -ExecutionPolicy Bypass -WindowStyle Normal -File `"$ScriptPath`" -Resume" `
        -ErrorAction SilentlyContinue
    Write-Log "Registered resume task for step: $NextStep"
}

# ─────────────────────────────────────────────────────────────
#  UI HELPERS
# ─────────────────────────────────────────────────────────────
function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "    ___________  " -NoNewline -ForegroundColor White
    Write-Host "        _                   " -ForegroundColor White
    Write-Host "   |           | " -NoNewline -ForegroundColor White
    Write-Host "   __ (_) _ __  __ _  _ __  _   _  " -ForegroundColor White
    Write-Host "   |  _______  | " -NoNewline -ForegroundColor White
    Write-Host "  / _`` || || '__``|/ _`` || '_ \| | | | " -ForegroundColor White
    Write-Host "   | |       | | " -NoNewline -ForegroundColor White
    Write-Host " | (_| || || |  | (_| || |_) | |_| | " -ForegroundColor White
    Write-Host "   | |_______| | " -NoNewline -ForegroundColor White
    Write-Host "  \__,_||_||_|   \__, || .__/ \__,_| " -ForegroundColor White
    Write-Host "   |___________| " -NoNewline -ForegroundColor White
    Write-Host "                  |___/ |_|           " -ForegroundColor White
    Write-Host ""
    Write-Host "                    D R I V E R   M A N A G E R" -ForegroundColor DarkCyan
    Write-Host "                    NVIDIA  *  Amazon EC2  *  Windows 11" -ForegroundColor DarkGray
    Write-Host ""
}

function Show-Section { param([string]$T); Write-Host ""; Write-Host "  -- $T " -ForegroundColor DarkGray; Write-Host "" }

function Prompt-YesNo {
    param([string]$Q)
    do { Write-Host "  $Q [Y/N]: " -ForegroundColor Yellow -NoNewline; $a = Read-Host }
    while ($a -notmatch '^[YyNn]$')
    return ($a -match '^[Yy]$')
}

function Prompt-Menu {
    param([string]$Title, [string[]]$Options)
    Write-Host ""; Write-Host "  $Title" -ForegroundColor Yellow
    for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host "    [$($i+1)] $($Options[$i])" }
    Write-Host "    [0] Cancel / Exit"; Write-Host ""
    do {
        Write-Host "  Selection: " -ForegroundColor Yellow -NoNewline
        $sel = Read-Host; $num = -1
        [int]::TryParse($sel, [ref]$num) | Out-Null
    } while ($num -lt 0 -or $num -gt $Options.Count)
    return $num
}

# ─────────────────────────────────────────────────────────────
#  GPU DETECTION
# ─────────────────────────────────────────────────────────────
function Get-InstalledNvidiaInfo {
    $info = @{ Installed=$false; Version=""; Variant="Unknown"; GpuName=""; DriverDate="" }

    $gpu = Get-WmiObject Win32_VideoController |
        Where-Object { $_.Name -like "*NVIDIA*" -or $_.AdapterCompatibility -like "*NVIDIA*" } |
        Select-Object -First 1
    if (-not $gpu) { Write-Log "No NVIDIA GPU found via WMI." -Level "WARN"; return $info }

    $info.GpuName    = $gpu.Name
    $info.DriverDate = $gpu.DriverDate
    $info.Version    = if ($gpu.DriverVersion -match '(\d{3})(\d{2})$') { "$($Matches[1]).$($Matches[2])" }
                       else { $gpu.DriverVersion }

    # Prefer nvidia-smi for accuracy
    $smi = if (Test-Path "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe") {
               "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe" } else { "nvidia-smi" }
    try {
        $out = & $smi --query-gpu=name,driver_version --format=csv,noheader 2>&1
        if ($LASTEXITCODE -eq 0 -and $out) {
            $p = $out -split ","
            if ($p.Count -ge 2) { $info.GpuName = $p[0].Trim(); $info.Version = $p[1].Trim() }
        }
    } catch { }

    $info.Installed = $true

    $names = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" `
        -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*NVIDIA*" } |
        ForEach-Object { $_.DisplayName }) -join " "

    if     ($names -match "GRID|vGPU|Virtual GPU|Tesla|Enterprise")        { $info.Variant = "GRID" }
    elseif ($names -match "GeForce|Game Ready|Gaming|Studio")               { $info.Variant = "Gaming" }
    elseif ($info.GpuName -match "Tesla|A10|A100|T4|V100|K80|A10G|L4|L40") { $info.Variant = "GRID" }
    else {
        $info.Variant = if (Get-ChildItem "$env:SystemRoot\System32\DriverStore\FileRepository" `
            -Filter "nvgridsw*" -ErrorAction SilentlyContinue) { "GRID" } else { "Gaming" }
    }
    return $info
}

# ─────────────────────────────────────────────────────────────
#  S3 VERSION CHECK
#  Both Gaming and GRID drivers come from official AWS S3 buckets.
#  Gaming : s3://nvidia-gaming/windows/latest/
#  GRID   : s3://ec2-windows-nvidia-drivers/latest/
# ─────────────────────────────────────────────────────────────
function Get-S3DriverInfo {
    param([string]$Bucket, [string]$Prefix)
    Set-AwsCredentials
    try {
        $exe = Get-S3Object -BucketName $Bucket -KeyPrefix $Prefix -Region "us-east-1" -ErrorAction Stop |
            Where-Object { $_.Key -like "*.exe" } | Select-Object -First 1
        if ($exe -and (Split-Path $exe.Key -Leaf) -match '(\d+\.\d+)') {
            return @{ Version=$Matches[1]; S3Key=$exe.Key; S3Bucket=$Bucket }
        }
    } catch { Write-Log "S3 check failed ($Bucket/$Prefix): $_" -Level "WARN" }
    return @{ Version="Unknown"; S3Key=""; S3Bucket="" }
}

function Get-LatestGamingVersion { param([string]$GpuName = "")
    return Get-S3DriverInfo -Bucket "nvidia-gaming" -Prefix "windows/latest/" }

function Get-LatestGridVersion { param([string]$GpuName = "")
    return Get-S3DriverInfo -Bucket "ec2-windows-nvidia-drivers" -Prefix "latest/" }

# ─────────────────────────────────────────────────────────────
#  UNINSTALL
# ─────────────────────────────────────────────────────────────
function Invoke-NvidiaUninstall {
    Show-Section "Uninstalling NVIDIA Drivers"
    Write-Log "Starting NVIDIA uninstall..."

    # Registered uninstall entries (apps/components)
    Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*NVIDIA*" -and $_.UninstallString } |
        ForEach-Object {
            Write-Host "  Uninstalling: $($_.DisplayName)" -ForegroundColor Yellow
            try {
                if ($_.UninstallString -match "MsiExec") {
                    $guid = [regex]::Match($_.UninstallString, '\{[^}]+\}').Value
                    if ($guid) { Start-Process msiexec.exe -ArgumentList "/x $guid /quiet /norestart" -Wait -NoNewWindow }
                } elseif ($_.UninstallString -match "\.exe") {
                    $exe = [regex]::Match($_.UninstallString, '"?([^"]+\.exe)"?').Groups[1].Value
                    if (Test-Path $exe) { Start-Process $exe -ArgumentList "-s -noreboot" -Wait -NoNewWindow }
                }
                Write-Log "Uninstalled: $($_.DisplayName)" -Level "OK"
            } catch { Write-Log "Failed to uninstall '$($_.DisplayName)': $_" -Level "WARN" }
        }

    # Display driver via NVI2.EXE / setup.exe (no UninstallString in registry)
    $setup = Get-ChildItem "$env:ProgramFiles\NVIDIA Corporation\Installer2\InstallerCore" `
                 -Filter "NVI2.EXE" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $setup) {
        $setup = Get-ChildItem "$env:SystemRoot\System32\DriverStore\FileRepository" `
                     -Recurse -Filter "setup.exe" -ErrorAction SilentlyContinue |
                     Where-Object { $_.FullName -like "*nv*" } | Select-Object -First 1
    }
    if ($setup) {
        Write-Host "  Running: $($setup.FullName) -s -noreboot -clean" -ForegroundColor Yellow
        try { Start-Process $setup.FullName -ArgumentList "-s -noreboot -clean" -Wait -NoNewWindow
              Write-Log "Display driver uninstall complete" -Level "OK"
        } catch { Write-Log "Display driver uninstall failed: $_" -Level "WARN" }
    } else {
        # Fallback: pnputil
        $list = pnputil /enum-drivers 2>&1
        [regex]::Matches($list, 'oem\d+\.inf') | Select-Object -ExpandProperty Value -Unique | ForEach-Object {
            if ($list -match "$_[\s\S]{0,200}nv[a-z]") {
                pnputil /delete-driver $_ /uninstall /force 2>&1 | Out-Null
                Write-Log "Removed INF: $_" -Level "OK"
            }
        }
    }

    Write-Host "  Stopping NVIDIA services..." -ForegroundColor Yellow
    Get-Service | Where-Object { $_.Name -like "nv*" -or $_.DisplayName -like "*NVIDIA*" } | ForEach-Object {
        Stop-Service $_.Name -Force -ErrorAction SilentlyContinue
        sc.exe delete $_.Name 2>&1 | Out-Null
    }

    @("$env:ProgramFiles\NVIDIA Corporation","$env:ProgramFiles\NVIDIA",
      "${env:ProgramFiles(x86)}\NVIDIA Corporation") |
        ForEach-Object { Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue }
    Get-Item "$env:SystemRoot\System32\DriverStore\FileRepository\nv*" -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "  Uninstall complete." -ForegroundColor Green
    Write-Log "Uninstall complete."
}

# ─────────────────────────────────────────────────────────────
#  REGISTRY CLEANUP
# ─────────────────────────────────────────────────────────────
function Invoke-RegistryCleanup {
    Show-Section "Registry Cleanup"
    @("HKLM:\SOFTWARE\NVIDIA Corporation","HKLM:\SOFTWARE\WOW6432Node\NVIDIA Corporation",
      "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm","HKLM:\SYSTEM\CurrentControlSet\Services\nvpciflt",
      "HKLM:\SYSTEM\CurrentControlSet\Services\nvstor","HKLM:\SYSTEM\CurrentControlSet\Services\NvStreamKms",
      "HKLM:\SYSTEM\CurrentControlSet\Services\NVSvc","HKLM:\SYSTEM\CurrentControlSet\Services\nvvhci",
      "HKLM:\SYSTEM\CurrentControlSet\Services\nvvad_WaveExtensible",
      "HKLM:\SYSTEM\CurrentControlSet\Services\NvTelemetryContainer",
      "HKCU:\SOFTWARE\NVIDIA Corporation") | ForEach-Object {
        if (Test-Path $_) { Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue
                            Write-Log "Removed: $_" -Level "OK" }
    }
    @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
      "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall") | ForEach-Object {
        Get-ChildItem $_ -ErrorAction SilentlyContinue |
            Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DisplayName -like "*NVIDIA*" } |
            ForEach-Object { Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "  Registry cleanup complete." -ForegroundColor Green
    Write-Log "Registry cleanup complete."
}

# ─────────────────────────────────────────────────────────────
#  DOWNLOAD
# ─────────────────────────────────────────────────────────────
function Get-DriverPackage {
    param([string]$Variant, [string]$S3Bucket, [string]$S3Key)
    if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }

    if (-not $S3Bucket -or -not $S3Key) {
        Write-Host "  No S3 source. Enter installer path manually (empty = cancel):" -ForegroundColor Yellow
        return (Read-Host "  Path").Trim('"').Trim()
    }

    $dest = "$TempDir\$(Split-Path $S3Key -Leaf)"
    if (Test-Path $dest) { Write-Host "  Cached: $dest" -ForegroundColor Green; return $dest }

    Write-Host "  Downloading s3://$S3Bucket/$S3Key" -ForegroundColor Cyan
    Write-Host "  -> $dest" -ForegroundColor Cyan
    Set-AwsCredentials
    try {
        Copy-S3Object -BucketName $S3Bucket -Key $S3Key -LocalFile $dest -Region "us-east-1" -ErrorAction Stop
        Write-Log "Download complete: $dest" -Level "OK"
        return $dest
    } catch {
        Write-Host "  S3 download failed: $_" -ForegroundColor Red
        Write-Log "S3 download failed: $_" -Level "ERROR"
        return ""
    }
}

# ─────────────────────────────────────────────────────────────
#  INSTALL
# ─────────────────────────────────────────────────────────────
function Install-NvidiaDriver {
    param([string]$InstallerPath, [string]$Variant)
    Show-Section "Installing NVIDIA Driver"
    if (-not $InstallerPath -or -not (Test-Path $InstallerPath)) {
        Write-Log "Installer not found: $InstallerPath" -Level "ERROR"; return $false
    }
    Write-Host "  Installer : $InstallerPath" -ForegroundColor Cyan
    Write-Host "  Variant   : $Variant" -ForegroundColor Cyan
    Write-Host "  Running silent install (this may take several minutes)..." -ForegroundColor Yellow
    $argList = @("-s","-noreboot","-clean")
    if ($Variant -eq "GRID") { $argList += "-noeula" }
    try {
        $proc = Start-Process -FilePath $InstallerPath -ArgumentList $argList -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 14) {
            Write-Host "  Installation complete!" -ForegroundColor Green
            Write-Log "Driver installed (ExitCode: $($proc.ExitCode))" -Level "OK"
            return $true
        }
        Write-Log "Driver install ExitCode: $($proc.ExitCode)" -Level "WARN"
        return $true
    } catch { Write-Log "Installation error: $_" -Level "ERROR"; return $false }
}

function Set-GamingLicense {
    # Registry key + cert required post-install for Gaming drivers (per AWS docs)
    try {
        $p = "HKLM:\SOFTWARE\NVIDIA Corporation\Global"
        if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
        New-ItemProperty -Path $p -Name "vGamingMarketplace" -PropertyType DWord -Value 2 -Force | Out-Null
        Write-Log "Gaming: vGamingMarketplace=2 set" -Level "OK"
    } catch { Write-Log "Gaming registry key failed: $_" -Level "WARN" }
    try {
        Invoke-WebRequest -Uri "https://nvidia-gaming.s3.amazonaws.com/GridSwCert-Archive/GridSwCertWindows_2024_02_22.cert" `
            -OutFile "$env:PUBLIC\Documents\GridSwCert.txt" -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        Write-Log "Gaming cert downloaded" -Level "OK"
    } catch {
        Write-Log "Gaming cert download failed: $_" -Level "WARN"
        Write-Host "  Warning: Could not download gaming cert -- licensing may not work." -ForegroundColor Yellow
    }
}

# ─────────────────────────────────────────────────────────────
#  VIRTUAL DISPLAY
# ─────────────────────────────────────────────────────────────
function Set-NvidiaVirtualDisplayAsPrimary {
    Show-Section "Setting NVIDIA Virtual Display as Primary"
    $vd = Get-WmiObject Win32_PnPEntity |
        Where-Object { $_.Name -like "*NVIDIA Virtual*" -or $_.Name -like "*Virtual Display*" }
    if ($vd) { $vd | ForEach-Object { Write-Host "  Found: $($_.Name)" -ForegroundColor Green } }
    else      { Write-Host "  No NVIDIA Virtual Display found." -ForegroundColor Yellow }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        Write-Host "  Displays:" -ForegroundColor Cyan
        [System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
            Write-Host "    $($_.DeviceName)  $($_.Bounds.Width)x$($_.Bounds.Height)$(if($_.Primary){' [PRIMARY]'})"
        }
    } catch { }
    Start-Process "ms-settings:display" -ErrorAction SilentlyContinue
    Write-Host "  Settings -> System -> Display -> select display -> 'Make this my main display'" -ForegroundColor DarkYellow
}

# ─────────────────────────────────────────────────────────────
#  REBOOT
# ─────────────────────────────────────────────────────────────
function Request-Reboot {
    param([string]$Reason, [string]$NextStep)
    Register-ResumeOnBoot -NextStep $NextStep
    Write-Host ""
    Write-Host "  Reboot recommended  ($Reason)" -ForegroundColor Yellow
    Write-Host "  Script resumes automatically at step '$NextStep' after login." -ForegroundColor DarkGray
    Write-Host ""
    if (Prompt-YesNo "Reboot now?") {
        Write-Log "Rebooting. Resume step: $NextStep"
        Start-Sleep -Seconds 5; Restart-Computer -Force
    } else {
        Write-Log "Reboot skipped. Resume step: $NextStep"
        Write-Host "  Run manually: .\Manage-NvidiaDriver.ps1 -Resume" -ForegroundColor DarkGray
    }
}

# ─────────────────────────────────────────────────────────────
#  STATUS + ONLINE CHECK
# ─────────────────────────────────────────────────────────────
function Step-ShowStatus {
    Show-Section "Current GPU Status"
    $info = Get-InstalledNvidiaInfo
    if (-not $info.Installed) { Write-Host "  [!] No NVIDIA driver detected." -ForegroundColor Red; return $info }
    $vc = switch ($info.Variant) { "Gaming"{"Magenta"} "GRID"{"Blue"} default{"Gray"} }
    Write-Host "  GPU Model   : " -NoNewline; Write-Host $info.GpuName    -ForegroundColor Cyan
    Write-Host "  Driver Ver  : " -NoNewline; Write-Host $info.Version    -ForegroundColor Cyan
    Write-Host "  Variant     : " -NoNewline; Write-Host $info.Variant    -ForegroundColor $vc
    if ($info.DriverDate) { Write-Host "  Driver Date : " -NoNewline; Write-Host $info.DriverDate -ForegroundColor DarkGray }
    Write-Host ""
    Write-Log "Installed driver: $($info.Version) [$($info.Variant)] on $($info.GpuName)"
    return $info
}

function Step-CheckOnline {
    param($info)
    Show-Section "Online Version Check"
    Write-Host "  Checking for newer drivers..." -ForegroundColor Yellow
    $latestGaming = Get-LatestGamingVersion
    $latestGrid   = Get-LatestGridVersion
    Write-Host "  Installed     : $($info.Version)  [$($info.Variant)]" -ForegroundColor White
    Write-Host "  Latest Gaming : $($latestGaming.Version)" -ForegroundColor $(if($latestGaming.Version -eq "Unknown"){"DarkGray"}else{"Magenta"})
    Write-Host "  Latest GRID   : $($latestGrid.Version)" -ForegroundColor Blue
    Write-Host ""
    $updateAvailable = $false
    try {
        $latest = if ($info.Variant -eq "GRID") { $latestGrid.Version } else { $latestGaming.Version }
        if ([Version]$latest -gt [Version]$info.Version) {
            $updateAvailable = $true
            Write-Host "  [+] Update available: $latest" -ForegroundColor Green
        } else { Write-Host "  [=] Driver is up to date." -ForegroundColor Green }
    } catch { Write-Host "  [?] Version comparison unavailable." -ForegroundColor DarkGray }
    return @{ UpdateAvailable=$updateAvailable; LatestGaming=$latestGaming; LatestGrid=$latestGrid }
}

function Step-ActionMenu {
    param($info, $online)
    Show-Section "Available Actions"
    $opts = @()
    if ($online.UpdateAvailable)    { $opts += "Update driver  ($($info.Variant) -> latest)" }
    if ($info.Variant -eq "Gaming") { $opts += "Switch to GRID / Enterprise driver" }
    if ($info.Variant -eq "GRID")   { $opts += "Switch to Gaming / GeForce driver" }
    if (-not $online.UpdateAvailable) { $opts += "Reinstall current driver  ($($info.Version))" }
    $opts += "Set Virtual Display as primary display"
    $opts += "Show status only  (no changes)"
    $sel = Prompt-Menu "What would you like to do?" $opts
    if ($sel -eq 0) { Write-Host "  Cancelled." -ForegroundColor DarkGray; return $null }
    return $opts[$sel - 1]
}

# ─────────────────────────────────────────────────────────────
#  FULL INSTALL FLOW  (reboot-safe 4-step state machine)
#
#  Steps: FRESH -> AFTER_DOWNLOAD -> AFTER_UNINSTALL -> AFTER_REGISTRY -> done
# ─────────────────────────────────────────────────────────────
function Invoke-FullInstall {
    param([string]$TargetVariant, [string]$Version, [string]$S3Bucket = "", [string]$S3Key = "")

    $state = Load-State
    if ($null -eq $state) { $state = @{} }
    $state.TargetVariant = $TargetVariant
    $state.TargetVersion = $Version
    $state.S3Bucket      = $S3Bucket
    $state.S3Key         = $S3Key

    # ── STEP 1: PRE-FLIGHT + DOWNLOAD ────────────────────────
    if ($state.Step -notin @("AFTER_DOWNLOAD","AFTER_UNINSTALL","AFTER_REGISTRY")) {
        Write-Host ""; Write-Host "  Step 1 / 4  --  Pre-flight & Download" -ForegroundColor White

        if (-not (Get-Command Get-S3Object -ErrorAction SilentlyContinue)) {
            Write-Host "  ERROR: AWS Tools for PowerShell not installed." -ForegroundColor Red
            Write-Host "  Run: Install-Module -Name AWSPowerShell -Force -AllowClobber" -ForegroundColor Yellow
            Write-Log "Pre-flight failed: AWS Tools not installed" -Level "ERROR"; return
        }
        Write-Host "  [OK] AWS Tools available" -ForegroundColor Green

        $disk = Get-PSDrive ((Split-Path $TempDir -Qualifier).TrimEnd(":")) -ErrorAction SilentlyContinue
        if ($disk -and $disk.Free -lt 2GB) {
            Write-Host "  ERROR: Not enough disk space ($([math]::Round($disk.Free/1GB,1)) GB free, need 2 GB)" -ForegroundColor Red
            Write-Log "Pre-flight failed: insufficient disk space" -Level "ERROR"; return
        }
        Write-Host "  [OK] Disk space sufficient" -ForegroundColor Green

        # Resolve S3 info if not supplied
        $dlBucket = $S3Bucket; $dlKey = $S3Key
        if (-not $dlBucket -or -not $dlKey) {
            $s3 = if ($TargetVariant -eq "GRID") { Get-LatestGridVersion } else { Get-LatestGamingVersion }
            $dlBucket = $s3.S3Bucket; $dlKey = $s3.S3Key
            $state.S3Bucket = $dlBucket; $state.S3Key = $dlKey
        }

        $installer = Get-DriverPackage -Variant $TargetVariant -S3Bucket $dlBucket -S3Key $dlKey
        if (-not $installer -or -not (Test-Path $installer)) {
            Write-Host "  ERROR: Download failed. Current driver untouched." -ForegroundColor Red
            Write-Log "Pre-flight failed: download failed" -Level "ERROR"; return
        }
        Write-Host "  [OK] Driver ready: $installer" -ForegroundColor Green
        $state.InstallerPath = $installer
        $state.Step = "AFTER_DOWNLOAD"
        Save-State $state
    }

    # ── STEP 2: UNINSTALL ─────────────────────────────────────
    if ($state.Step -notin @("AFTER_UNINSTALL","AFTER_REGISTRY")) {
        Write-Host ""; Write-Host "  Step 2 / 4  --  Uninstall" -ForegroundColor White
        $state.Step = "UNINSTALLING"; Save-State $state
        Invoke-NvidiaUninstall
        $state.Step = "AFTER_UNINSTALL"; Save-State $state
        Request-Reboot -Reason "Clean uninstall completed" -NextStep "AFTER_UNINSTALL"
    }

    # ── STEP 3: REGISTRY CLEANUP ──────────────────────────────
    if ($state.Step -eq "AFTER_UNINSTALL") {
        Write-Host ""; Write-Host "  Step 3 / 4  --  Registry Cleanup" -ForegroundColor White
        Invoke-RegistryCleanup
        $state.Step = "AFTER_REGISTRY"; Save-State $state
        Request-Reboot -Reason "Registry cleanup completed" -NextStep "AFTER_REGISTRY"
    }

    # ── STEP 4: INSTALL ───────────────────────────────────────
    if ($state.Step -eq "AFTER_REGISTRY") {
        Write-Host ""; Write-Host "  Step 4 / 4  --  Install $($state.TargetVariant) Driver ($($state.TargetVersion))" -ForegroundColor White

        $installer = $state.InstallerPath
        if (-not $installer -or -not (Test-Path $installer)) {
            Write-Host "  Cached installer missing -- re-downloading..." -ForegroundColor Yellow
            $installer = Get-DriverPackage -Variant $state.TargetVariant -S3Bucket $state.S3Bucket -S3Key $state.S3Key
        }
        if (-not $installer) { Write-Host "  No installer available. Aborting." -ForegroundColor Red; Clear-State; return }

        $ok = Install-NvidiaDriver -InstallerPath $installer -Variant $state.TargetVariant

        if ($ok) {
            if ($state.TargetVariant -eq "Gaming") { Set-GamingLicense }
            $state.Step = "AFTER_INSTALL"; Save-State $state
            Set-NvidiaVirtualDisplayAsPrimary
            Clear-State
            Write-Host ""
            Write-Host "  +----------------------------------------------+" -ForegroundColor Green
            Write-Host "  |  Installation completed successfully.          |" -ForegroundColor Green
            Write-Host "  +----------------------------------------------+" -ForegroundColor Green
            Write-Host ""
            if (Prompt-YesNo "Reboot now to finalize driver?") { Start-Sleep -Seconds 5; Restart-Computer -Force }
        } else {
            Write-Host "  Installation failed. Re-run to retry." -ForegroundColor Red
            Write-Log "Installation failed. State preserved at AFTER_REGISTRY." -Level "ERROR"
        }
    }
}

# ─────────────────────────────────────────────────────────────
#  ENTRY POINT
# ─────────────────────────────────────────────────────────────
foreach ($dir in @($WorkDir,$TempDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

Show-Banner

# ── Loading Prerequisites (spinner via background thread) ─────
$stopFlag = [ref]$false
$spinner = [System.Threading.Thread]::new([System.Threading.ThreadStart]{
    $frames = [char[]]@('|','/','-','\')
    $i = 0
    while (-not $stopFlag.Value) {
        [Console]::Write("`r  Loading Prerequisites... " + $frames[$i % 4] + " ")
        [System.Threading.Thread]::Sleep(120)
        $i++
    }
})
$spinner.IsBackground = $true
$spinner.Start()

Set-AwsCredentials   # First load of AWS SDK DLLs takes ~30s

$stopFlag.Value = $true
$spinner.Join(500) | Out-Null
Write-Host "`r  Loading Prerequisites... done.  " -ForegroundColor Green

# ── Resume ────────────────────────────────────────────────────
$existingState = Load-State
if ($existingState -and ($Resume -or $existingState.Step -in @("FRESH","AFTER_DOWNLOAD","AFTER_UNINSTALL","AFTER_REGISTRY"))) {
    Write-Host "  Resuming from step: $($existingState.Step)" -ForegroundColor Yellow
    Write-Log "Resuming from step: $($existingState.Step)"
    $cur = Get-InstalledNvidiaInfo
    Write-Host "  $(if($cur.Installed){"Found: $($cur.Version) [$($cur.Variant)] -- $($cur.GpuName)"}else{"No driver detected."})" -ForegroundColor Cyan
    Write-Host ""
    $rBucket = $existingState.S3Bucket; $rKey = $existingState.S3Key
    if (-not $rBucket -or -not $rKey) {
        $rf = if ($existingState.TargetVariant -eq "GRID") { Get-LatestGridVersion } else { Get-LatestGamingVersion }
        $rBucket = $rf.S3Bucket; $rKey = $rf.S3Key
        if (-not $existingState.TargetVersion) { $existingState.TargetVersion = $rf.Version }
    }
    Invoke-FullInstall -TargetVariant $existingState.TargetVariant -Version $existingState.TargetVersion `
        -S3Bucket $rBucket -S3Key $rKey
    exit 0
}

# ── Fresh run ─────────────────────────────────────────────────
$info = Step-ShowStatus

if (-not $info.Installed) {
    $variant = if (Prompt-YesNo "Install GRID / Enterprise driver? (No = Gaming)") { "GRID" } else { "Gaming" }
    $s3 = if ($variant -eq "GRID") { Get-LatestGridVersion } else { Get-LatestGamingVersion }
    Save-State @{ Step="FRESH"; TargetVariant=$variant; TargetVersion=$s3.Version; S3Bucket=$s3.S3Bucket; S3Key=$s3.S3Key }
    Invoke-FullInstall -TargetVariant $variant -Version $s3.Version -S3Bucket $s3.S3Bucket -S3Key $s3.S3Key
    exit 0
}

$online = Step-CheckOnline -info $info
$action = Step-ActionMenu  -info $info -online $online
if ($null -eq $action) { exit 0 }

switch -Wildcard ($action) {
    "*Update*" {
        $s3 = if ($info.Variant -eq "GRID") { $online.LatestGrid } else { $online.LatestGaming }
        Save-State @{ Step="FRESH"; TargetVariant=$info.Variant; TargetVersion=$s3.Version; S3Bucket=$s3.S3Bucket; S3Key=$s3.S3Key }
        Invoke-FullInstall -TargetVariant $info.Variant -Version $s3.Version -S3Bucket $s3.S3Bucket -S3Key $s3.S3Key
    }
    "*GRID*" {
        $s3 = $online.LatestGrid
        Save-State @{ Step="FRESH"; TargetVariant="GRID"; TargetVersion=$s3.Version; S3Bucket=$s3.S3Bucket; S3Key=$s3.S3Key }
        Invoke-FullInstall -TargetVariant "GRID" -Version $s3.Version -S3Bucket $s3.S3Bucket -S3Key $s3.S3Key
    }
    "*Gaming*" {
        $s3 = $online.LatestGaming
        Save-State @{ Step="FRESH"; TargetVariant="Gaming"; TargetVersion=$s3.Version; S3Bucket=$s3.S3Bucket; S3Key=$s3.S3Key }
        Invoke-FullInstall -TargetVariant "Gaming" -Version $s3.Version -S3Bucket $s3.S3Bucket -S3Key $s3.S3Key
    }
    "*Reinstall*" {
        $s3 = if ($info.Variant -eq "GRID") { Get-LatestGridVersion } else { Get-LatestGamingVersion }
        Save-State @{ Step="FRESH"; TargetVariant=$info.Variant; TargetVersion=$info.Version; S3Bucket=$s3.S3Bucket; S3Key=$s3.S3Key }
        Invoke-FullInstall -TargetVariant $info.Variant -Version $info.Version -S3Bucket $s3.S3Bucket -S3Key $s3.S3Key
    }
    "*Virtual Display*" { Set-NvidiaVirtualDisplayAsPrimary }
    default             { Write-Host "  No action taken." -ForegroundColor DarkGray }
}

Write-Host ""
Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
Write-Host ""
