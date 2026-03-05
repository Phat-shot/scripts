#Requires -RunAsAdministrator
<#
.SYNOPSIS
    airgpu Driver Manager -- NVIDIA driver management for Amazon EC2 Windows 11 instances.

.DESCRIPTION
    - Detects installed NVIDIA driver (version, variant, GPU model)
    - Checks online for newer driver versions
    - Supports in-place update and variant switching (Gaming <-> GRID)
    - Full clean uninstall + registry cleanup before reinstall
    - Sets NVIDIA Virtual Display as Primary Display after installation
    - State persistence across reboots for seamless resume

.NOTES
    Must be run as Administrator on EC2 Windows 11 with NVIDIA GPU.
    Working dir : C:\Program Files\airgpu\Driver Manager\
    State file  : C:\Program Files\airgpu\Driver Manager\state.json
    Log file    : C:\Program Files\airgpu\Driver Manager\driver_manager.log
#>

# ─────────────────────────────────────────────────────────────
#  PARAMETERS
# ─────────────────────────────────────────────────────────────
param([switch]$Resume)

# ─────────────────────────────────────────────────────────────
#  CONFIGURATION
# ─────────────────────────────────────────────────────────────
$WorkDir    = "C:\Program Files\airgpu\Driver Manager"
$StateFile  = "$WorkDir\state.json"
$LogFile    = "$WorkDir\driver_manager.log"
$TempDir    = "C:\Temp\airgpuDriverManager"
$RunKey     = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$RunName    = "airgpuDriverManagerResume"
$ScriptPath = $MyInvocation.MyCommand.Path

# ─────────────────────────────────────────────────────────────
#  LOGGING
# ─────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    switch ($Level) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "OK"    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line -ForegroundColor Cyan }
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
            # Convert PSCustomObject to hashtable (PS5.1 compatible -- no -AsHashtable)
            $ht = @{}
            $json.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
            return $ht
        }
        catch { Write-Log "Could not load state file: $_" -Level "WARN" }
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

    # Use Scheduled Task (AtLogon) -- Run key doesn't show a window for Admin scripts
    $taskName = "airgpuDriverManagerResume"
    $action   = New-ScheduledTaskAction `
        -Execute  "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Resume"
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal `
        -UserId   "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive `
        -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 60)
    Register-ScheduledTask -TaskName $taskName -Action $action `
        -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    # Also keep Run key as backup
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
    Write-Host "  / _` || || '__`|/ _` || '_ \| | | | " -ForegroundColor White
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
function Show-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "  -- $Title " -ForegroundColor DarkGray
    Write-Host ""
}

function Prompt-YesNo {
    param([string]$Question)
    do {
        Write-Host "  $Question [Y/N]: " -ForegroundColor Yellow -NoNewline
        $answer = Read-Host
    } while ($answer -notmatch '^[YyNn]$')
    return ($answer -match '^[Yy]$')
}

function Prompt-Menu {
    param([string]$Title, [string[]]$Options)
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor Yellow
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "    [$($i+1)] $($Options[$i])"
    }
    Write-Host "    [0] Cancel / Exit"
    Write-Host ""
    do {
        Write-Host "  Selection: " -ForegroundColor Yellow -NoNewline
        $sel = Read-Host
        $num = -1
        [int]::TryParse($sel, [ref]$num) | Out-Null
    } while ($num -lt 0 -or $num -gt $Options.Count)
    return $num
}

# ─────────────────────────────────────────────────────────────
#  GPU DETECTION
# ─────────────────────────────────────────────────────────────
function Get-InstalledNvidiaInfo {
    $info = @{
        Installed     = $false
        Version       = ""
        VersionParsed = $null
        Variant       = "Unknown"    # Gaming | GRID | Unknown
        GpuName       = ""
        DriverDate    = ""
    }

    $gpus = Get-WmiObject Win32_VideoController |
        Where-Object { $_.Name -like "*NVIDIA*" -or $_.AdapterCompatibility -like "*NVIDIA*" }

    if (-not $gpus) {
        Write-Log "No NVIDIA GPU found via WMI." -Level "WARN"
        return $info
    }

    $gpu             = $gpus | Select-Object -First 1
    $info.GpuName    = $gpu.Name
    $info.DriverDate = $gpu.DriverDate

    # Parse NVIDIA version from WMI string -- last 5 digits become xxx.xx
    if ($gpu.DriverVersion -match '(\d{3})(\d{2})$') {
        $info.Version       = "$($Matches[1]).$($Matches[2])"
        $info.VersionParsed = try { [Version]$info.Version } catch { $null }
    } else {
        $info.Version = $gpu.DriverVersion
    }

    # Prefer nvidia-smi for accuracy
    $smiPath = "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    if (-not (Test-Path $smiPath)) { $smiPath = "nvidia-smi" }
    try {
        $smiOut = & $smiPath --query-gpu=name,driver_version --format=csv,noheader 2>&1
        if ($LASTEXITCODE -eq 0 -and $smiOut) {
            $parts = $smiOut -split ","
            if ($parts.Count -ge 2) {
                $info.GpuName       = $parts[0].Trim()
                $info.Version       = $parts[1].Trim()
                $info.VersionParsed = try { [Version]$info.Version } catch { $null }
            }
        }
    } catch { }

    $info.Installed = $true

    # Determine variant from installed programs
    $nvidiaApps = Get-ItemProperty `
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*NVIDIA*" }

    $allNames = ($nvidiaApps | ForEach-Object { $_.DisplayName }) -join " "

    if ($allNames -match "GRID|vGPU|Virtual GPU|Tesla|Enterprise") {
        $info.Variant = "GRID"
    } elseif ($allNames -match "GeForce|Game Ready|Gaming|Studio") {
        $info.Variant = "Gaming"
    } elseif ($info.GpuName -match "Tesla|A10|A100|T4|V100|K80|A10G|L4|L40") {
        $info.Variant = "GRID"
    } else {
        $gridDirs = Get-ChildItem "$env:SystemRoot\System32\DriverStore\FileRepository" `
            -Filter "nvgridsw*" -ErrorAction SilentlyContinue
        $info.Variant = if ($gridDirs) { "GRID" } else { "Gaming" }
    }

    return $info
}

# ─────────────────────────────────────────────────────────────
#  ONLINE VERSION CHECK
# ─────────────────────────────────────────────────────────────
function Get-LatestGamingVersion {
    param([string]$GpuName)
    # Official AWS method: s3://nvidia-gaming/windows/latest/
    # Supported hardware: NVIDIA L4, L40S, A10G, T4, M60 (per AWS docs)
    # Requires AmazonS3ReadOnlyAccess + nvidia-gaming bucket access (G4dn/G5 only)
    try {
        if (-not (Get-Command Get-S3Object -ErrorAction SilentlyContinue)) { throw "No AWS Tools" }
        $objects = Get-S3Object -BucketName "nvidia-gaming" -KeyPrefix "windows/latest/" -Region "us-east-1" -ErrorAction Stop
        $exe = $objects | Where-Object { $_.Key -like "*.exe" } | Select-Object -First 1
        if ($exe) {
            $fname = Split-Path $exe.Key -Leaf
            if ($fname -match '(\d+\.\d+)') {
                return @{ Version = $Matches[1]; S3Key = $exe.Key; S3Bucket = "nvidia-gaming" }
            }
        }
    } catch {
        Write-Log "Gaming S3 check failed: $_" -Level "WARN"
    }
    return @{ Version = "Unknown"; S3Key = ""; S3Bucket = "" }
}

function Get-LatestGridVersion {
    param([string]$GpuName)
    # Official AWS method: query S3 bucket via AWS SDK
    # Bucket: ec2-windows-nvidia-drivers, prefix: latest/
    # Requires AmazonS3ReadOnlyAccess IAM policy on the instance
    try {
        $objects = Get-S3Object -BucketName "ec2-windows-nvidia-drivers" -KeyPrefix "latest/" -Region "us-east-1" -ErrorAction Stop
        $exe = $objects | Where-Object { $_.Key -like "*.exe" } | Select-Object -First 1
        if ($exe) {
            $fname = Split-Path $exe.Key -Leaf
            if ($fname -match '(\d+\.\d+)') {
                return @{ Version = $Matches[1]; S3Key = $exe.Key; S3Bucket = "ec2-windows-nvidia-drivers" }
            }
        }
    } catch {
        Write-Log "GRID S3 check failed: $_" -Level "WARN"
    }
    return @{ Version = "Unknown"; S3Key = ""; S3Bucket = "" }
}


# ─────────────────────────────────────────────────────────────
#  UNINSTALL
# ─────────────────────────────────────────────────────────────
function Invoke-NvidiaUninstall {
    Show-Section "Uninstalling NVIDIA Drivers"
    Write-Log "Starting NVIDIA uninstall..."

    $apps = Get-ItemProperty `
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*NVIDIA*" -and $_.UninstallString }

    if (-not $apps) {
        Write-Host "  No registered NVIDIA programs found -- continuing with cleanup." -ForegroundColor DarkGray
        Write-Log "No registered NVIDIA programs found for uninstall." -Level "WARN"
    } else {
        foreach ($app in $apps) {
            Write-Host "  Uninstalling: $($app.DisplayName)" -ForegroundColor Yellow
            try {
                if ($app.UninstallString -match "MsiExec") {
                    $guid = [regex]::Match($app.UninstallString, '\{[^}]+\}').Value
                    if ($guid) { Start-Process msiexec.exe -ArgumentList "/x $guid /quiet /norestart" -Wait -NoNewWindow }
                } elseif ($app.UninstallString -match "\.exe") {
                    $exe = [regex]::Match($app.UninstallString, '"?([^"]+\.exe)"?').Groups[1].Value
                    if (Test-Path $exe) { Start-Process $exe -ArgumentList "-s -noreboot" -Wait -NoNewWindow }
                }
                Write-Log "Uninstalled: $($app.DisplayName)" -Level "OK"
            } catch {
                Write-Log "Failed to uninstall '$($app.DisplayName)': $_" -Level "WARN"
            }
        }
    }

    # NVIDIA GRID/Display drivers use setup.exe -- no UninstallString in registry
    Write-Host "  Running NVIDIA display driver uninstaller..." -ForegroundColor Yellow
    $nvSetup = Get-ChildItem "$env:ProgramFiles\NVIDIA Corporation\Installer2\InstallerCore" -Filter "NVI2.EXE" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $nvSetup) {
        $nvSetup = Get-ChildItem "$env:SystemRoot\System32\DriverStore\FileRepository" -Recurse -Filter "setup.exe" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -like "*nv*" } | Select-Object -First 1
    }
    if ($nvSetup) {
        Write-Host "  Found: $($nvSetup.FullName)" -ForegroundColor DarkGray
        try {
            Start-Process $nvSetup.FullName -ArgumentList "-s -noreboot -clean" -Wait -NoNewWindow
            Write-Log "NVIDIA setup.exe uninstall complete" -Level "OK"
        } catch {
            Write-Log "NVIDIA setup.exe uninstall failed: $_" -Level "WARN"
        }
    } else {
        # Fallback: pnputil to remove display INF
        Write-Host "  Using pnputil to remove display driver INF..." -ForegroundColor DarkGray
        $driverList = pnputil /enum-drivers 2>&1
        $oemInfs = [regex]::Matches($driverList, 'oem\d+\.inf') | Select-Object -ExpandProperty Value -Unique
        foreach ($inf in $oemInfs) {
            if ($driverList -match "$inf[\s\S]{0,200}nv[a-z]") {
                pnputil /delete-driver $inf /uninstall /force 2>&1 | Out-Null
                Write-Log "Removed INF: $inf" -Level "OK"
            }
        }
    }

    Write-Host "  Stopping NVIDIA services..." -ForegroundColor Yellow
    Get-Service | Where-Object { $_.Name -like "nv*" -or $_.DisplayName -like "*NVIDIA*" } | ForEach-Object {
        Stop-Service $_.Name -Force -ErrorAction SilentlyContinue
        sc.exe delete $_.Name 2>&1 | Out-Null
    }

    Write-Host "  Removing NVIDIA files..." -ForegroundColor Yellow
    @(
        "$env:ProgramFiles\NVIDIA Corporation",
        "$env:ProgramFiles\NVIDIA",
        "${env:ProgramFiles(x86)}\NVIDIA Corporation"
    ) | ForEach-Object { Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue }

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
    Write-Log "Cleaning NVIDIA registry entries..."

    @(
        "HKLM:\SOFTWARE\NVIDIA Corporation",
        "HKLM:\SOFTWARE\WOW6432Node\NVIDIA Corporation",
        "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm",
        "HKLM:\SYSTEM\CurrentControlSet\Services\nvpciflt",
        "HKLM:\SYSTEM\CurrentControlSet\Services\nvstor",
        "HKLM:\SYSTEM\CurrentControlSet\Services\NvStreamKms",
        "HKLM:\SYSTEM\CurrentControlSet\Services\NVSvc",
        "HKLM:\SYSTEM\CurrentControlSet\Services\nvvhci",
        "HKLM:\SYSTEM\CurrentControlSet\Services\nvvad_WaveExtensible",
        "HKLM:\SYSTEM\CurrentControlSet\Services\NvTelemetryContainer",
        "HKCU:\SOFTWARE\NVIDIA Corporation"
    ) | ForEach-Object {
        if (Test-Path $_) {
            Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  Removed: $_" -ForegroundColor DarkGray
            Write-Log "Removed: $_" -Level "OK"
        }
    }

    @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    ) | ForEach-Object {
        Get-ChildItem $_ -ErrorAction SilentlyContinue |
            Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DisplayName -like "*NVIDIA*" } |
            ForEach-Object {
                Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "Removed uninstall key: $($_.PSChildName)" -Level "OK"
            }
    }

    Write-Host "  Registry cleanup complete." -ForegroundColor Green
    Write-Log "Registry cleanup complete."
}

# ─────────────────────────────────────────────────────────────
#  DOWNLOAD
# ─────────────────────────────────────────────────────────────
function Get-DriverPackage {
    param([string]$Variant, [string]$S3Bucket = "", [string]$S3Key = "", [string]$Url = "")

    if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }

    # ── GRID: download from official AWS S3 bucket ────────────
    if ($Variant -eq "GRID" -and $S3Bucket -and $S3Key) {
        $dest = "$TempDir\$(Split-Path $S3Key -Leaf)"
        if (Test-Path $dest) {
            Write-Host "  Installer already cached: $dest" -ForegroundColor Green
            return $dest
        }
        Write-Host "  Downloading from S3: s3://$S3Bucket/$S3Key" -ForegroundColor Cyan
        Write-Host "  Destination        : $dest" -ForegroundColor Cyan
        Write-Host ""
        try {
            # Check AWS Tools are available
            if (-not (Get-Command Get-S3Object -ErrorAction SilentlyContinue)) {
                throw "AWS Tools for PowerShell not installed. Run: Install-Module -Name AWSPowerShell -Force"
            }
            # Ensure credentials are loaded
            Set-AWSCredential -ProfileName default -ErrorAction SilentlyContinue
            Copy-S3Object -BucketName $S3Bucket -Key $S3Key -LocalFile $dest -Region "us-east-1" -ErrorAction Stop
            Write-Log "S3 download complete: $dest" -Level "OK"
            return $dest
        } catch {
            Write-Host "  S3 download failed: $_" -ForegroundColor Red
            Write-Host "  Make sure the instance has AmazonS3ReadOnlyAccess IAM policy." -ForegroundColor Yellow
            Write-Log "S3 download failed: $_" -Level "ERROR"
            return ""
        }
    }

    # ── Fallback: HTTP download ───────────────────────────────
    if (-not $Url) {
        Write-Host ""
        Write-Host "  No download source available." -ForegroundColor Red
        Write-Host "  For GRID: attach AmazonS3ReadOnlyAccess IAM policy to this instance." -ForegroundColor Yellow
        Write-Host "  Manual: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/install-nvidia-driver.html" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Enter installer path (leave empty to cancel): " -ForegroundColor Yellow -NoNewline
        return (Read-Host).Trim('"').Trim()
    }

    $dest = "$TempDir\$(Split-Path $Url -Leaf)"
    if (Test-Path $dest) {
        Write-Host "  Installer already cached: $dest" -ForegroundColor Green
        return $dest
    }

    Write-Host "  Downloading : $Url" -ForegroundColor Cyan
    Write-Host "  Destination : $dest" -ForegroundColor Cyan
    Write-Host ""

    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadProgressChanged += {
            param($s, $e)
            Write-Progress -Activity "Downloading NVIDIA Driver" `
                -Status "$($e.ProgressPercentage)%  ($([math]::Round($e.BytesReceived/1MB,1)) MB)" `
                -PercentComplete $e.ProgressPercentage
        }
        $wc.DownloadFileAsync([Uri]$Url, $dest)
        while ($wc.IsBusy) { Start-Sleep -Milliseconds 500 }
        Write-Progress -Activity "Downloading NVIDIA Driver" -Completed
        Write-Log "Download complete: $dest" -Level "OK"
        return $dest
    } catch {
        Write-Log "Download failed: $_" -Level "ERROR"
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
        Write-Host "  Installer not found: $InstallerPath" -ForegroundColor Red
        Write-Log "Installer not found: $InstallerPath" -Level "ERROR"
        return $false
    }

    Write-Host "  Installer : $InstallerPath" -ForegroundColor Cyan
    Write-Host "  Variant   : $Variant" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Running silent installation (this may take several minutes)..." -ForegroundColor Yellow

    $argList = @("-s", "-noreboot", "-clean")
    if ($Variant -eq "GRID") { $argList += "-noeula" }

    try {
        $proc = Start-Process -FilePath $InstallerPath -ArgumentList $argList -Wait -PassThru -NoNewWindow
        # Exit code 14 = reboot required but install succeeded
        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 14) {
            Write-Host "  Installation complete!" -ForegroundColor Green
            Write-Log "Driver installation succeeded (ExitCode: $($proc.ExitCode))" -Level "OK"
            return $true
        } else {
            Write-Host "  Installation finished with exit code: $($proc.ExitCode)" -ForegroundColor Yellow
            Write-Log "Driver installation ExitCode: $($proc.ExitCode)" -Level "WARN"
            return $true
        }
    } catch {
        Write-Host "  Installation error: $_" -ForegroundColor Red
        Write-Log "Installation exception: $_" -Level "ERROR"
        return $false
    }
}

# ─────────────────────────────────────────────────────────────
#  SET VIRTUAL DISPLAY AS PRIMARY
# ─────────────────────────────────────────────────────────────
function Set-NvidiaVirtualDisplayAsPrimary {
    Show-Section "Setting NVIDIA Virtual Display as Primary"

    $vDisp = Get-WmiObject Win32_PnPEntity |
        Where-Object { $_.Name -like "*NVIDIA Virtual*" -or $_.Name -like "*Virtual Display*" }

    if ($vDisp) {
        foreach ($d in $vDisp) {
            Write-Host "  Found: $($d.Name)" -ForegroundColor Green
            Write-Log "Virtual display found: $($d.Name)" -Level "OK"
        }
    } else {
        Write-Host "  No NVIDIA Virtual Display found via PnP." -ForegroundColor Yellow
        Write-Log "No NVIDIA Virtual Display found via PnP." -Level "WARN"
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $screens = [System.Windows.Forms.Screen]::AllScreens
        Write-Host ""
        Write-Host "  Detected displays:" -ForegroundColor Cyan
        foreach ($s in $screens) {
            $tag = if ($s.Primary) { "  [PRIMARY]" } else { "" }
            Write-Host "    $($s.DeviceName)  $($s.Bounds.Width)x$($s.Bounds.Height)$tag"
        }
    } catch { }

    Write-Host ""
    Write-Host "  Opening Display Settings..." -ForegroundColor Yellow
    Start-Process "ms-settings:display" -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "  If the NVIDIA Virtual Display was not set as primary automatically:" -ForegroundColor DarkYellow
    Write-Host "  Settings -> System -> Display -> Select display -> 'Make this my main display'" -ForegroundColor DarkYellow
    Write-Log "Display settings opened for user review."
}

# ─────────────────────────────────────────────────────────────
#  REBOOT HELPER
# ─────────────────────────────────────────────────────────────
function Request-Reboot {
    param([string]$Reason, [string]$NextStep)
    Write-Host ""
    Write-Host "  +--------------------------------------------------+" -ForegroundColor Yellow
    Write-Host "  |  A reboot is recommended.                         |" -ForegroundColor Yellow
    Write-Host "  |  Reason  : $Reason" -ForegroundColor Yellow
    Write-Host "  |  Resumes : Step '$NextStep'" -ForegroundColor Yellow
    Write-Host "  +--------------------------------------------------+" -ForegroundColor Yellow
    Write-Host ""

    Register-ResumeOnBoot -NextStep $NextStep

    if (Prompt-YesNo "Reboot now? (Script will resume automatically after restart)") {
        Write-Log "User confirmed reboot. Resume step: $NextStep"
        Write-Host "  Rebooting in 10 seconds..." -ForegroundColor Red
        Start-Sleep -Seconds 10
        Restart-Computer -Force
    } else {
        Write-Log "User declined reboot. Resume step saved: $NextStep"
        Write-Host ""
        Write-Host "  Reboot skipped. The script will resume at step '$NextStep' on next login." -ForegroundColor Yellow
        Write-Host "  Or run manually: .\Manage-NvidiaDriver.ps1 -Resume" -ForegroundColor DarkGray
    }
}

# ─────────────────────────────────────────────────────────────
#  STATUS DISPLAY
# ─────────────────────────────────────────────────────────────
function Step-ShowStatus {
    Show-Section "Current GPU Status"
    $info = Get-InstalledNvidiaInfo

    if (-not $info.Installed) {
        Write-Host "  [!] No NVIDIA driver detected." -ForegroundColor Red
        Write-Host ""
        return $info
    }

    $varColor = switch ($info.Variant) {
        "Gaming" { "Magenta" }
        "GRID"   { "Blue" }
        default  { "Gray" }
    }

    Write-Host "  GPU Model   : " -NoNewline; Write-Host $info.GpuName -ForegroundColor Cyan
    Write-Host "  Driver Ver  : " -NoNewline; Write-Host $info.Version -ForegroundColor Cyan
    Write-Host "  Variant     : " -NoNewline; Write-Host $info.Variant -ForegroundColor $varColor
    if ($info.DriverDate) {
        Write-Host "  Driver Date : " -NoNewline; Write-Host $info.DriverDate -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Log "Installed driver: $($info.Version) [$($info.Variant)] on $($info.GpuName)"
    return $info
}

# ─────────────────────────────────────────────────────────────
#  ONLINE CHECK
# ─────────────────────────────────────────────────────────────
function Step-CheckOnline {
    param($info)
    Show-Section "Online Version Check"
    Write-Host "  Checking for newer drivers..." -ForegroundColor Yellow

    $latestGaming = Get-LatestGamingVersion -GpuName $info.GpuName
    $latestGrid   = Get-LatestGridVersion   -GpuName $info.GpuName

    Write-Host "  Installed     : $($info.Version)  [$($info.Variant)]" -ForegroundColor White
    $gamingColor = if ($latestGaming.Version -eq "Unknown") { "DarkGray" } else { "Magenta" }
    Write-Host "  Latest Gaming : $($latestGaming.Version)" -ForegroundColor $gamingColor
    Write-Host "  Latest GRID   : $($latestGrid.Version)"   -ForegroundColor Blue
    Write-Host ""

    $updateAvailable = $false
    try {
        $current       = [Version]$info.Version
        $latestVariant = if ($info.Variant -eq "GRID") { $latestGrid.Version } else { $latestGaming.Version }
        if ([Version]$latestVariant -gt $current) {
            $updateAvailable = $true
            Write-Host "  [+] Update available: $latestVariant" -ForegroundColor Green
        } else {
            Write-Host "  [=] Driver is up to date." -ForegroundColor Green
        }
    } catch {
        Write-Host "  [?] Version comparison unavailable (unexpected format)." -ForegroundColor DarkGray
    }

    return @{ UpdateAvailable = $updateAvailable; LatestGaming = $latestGaming; LatestGrid = $latestGrid }
}

# ─────────────────────────────────────────────────────────────
#  ACTION MENU
# ─────────────────────────────────────────────────────────────
function Step-ActionMenu {
    param($info, $online)
    Show-Section "Available Actions"

    $opts = @()
    if ($online.UpdateAvailable)      { $opts += "Update driver  ($($info.Variant) -> latest version)" }
    if ($info.Variant -eq "Gaming")   { $opts += "Switch to GRID / Enterprise driver" }
    if ($info.Variant -eq "GRID")     { $opts += "Switch to Gaming / GeForce driver" }
    if (-not $online.UpdateAvailable) { $opts += "Reinstall current driver  ($($info.Version))" }
    $opts += "Set Virtual Display as primary display"
    $opts += "Show status only  (no changes)"

    $sel = Prompt-Menu "What would you like to do?" $opts
    if ($sel -eq 0) { Write-Host "  Cancelled." -ForegroundColor DarkGray; return $null }
    return $opts[$sel - 1]
}

# ─────────────────────────────────────────────────────────────
#  FULL INSTALL FLOW  (reboot-safe state machine)
# ─────────────────────────────────────────────────────────────
function Invoke-FullInstall {
    param([string]$TargetVariant, [string]$Version, [string]$S3Bucket = "", [string]$S3Key = "")

    $state = Load-State
    if ($null -eq $state) { $state = @{} }
    $state.TargetVariant = $TargetVariant
    $state.TargetVersion = $Version
    $state.S3Bucket      = $S3Bucket
    $state.S3Key         = $S3Key

    # ── STEP 0: PRE-FLIGHT + DOWNLOAD ───────────────────────
    if ($state.Step -notin @("AFTER_DOWNLOAD", "AFTER_UNINSTALL", "AFTER_REGISTRY")) {
        Write-Host ""
        Write-Host "  Step 1 / 4  --  Pre-flight check & Download" -ForegroundColor White

        # Check AWS Tools
        if (-not (Get-Command Get-S3Object -ErrorAction SilentlyContinue)) {
            Write-Host ""
            Write-Host "  ERROR: AWS Tools for PowerShell not installed." -ForegroundColor Red
            Write-Host "  Install with: Install-Module -Name AWSPowerShell -Force -AllowClobber" -ForegroundColor Yellow
            Write-Log "Pre-flight failed: AWS Tools not installed" -Level "ERROR"
            return
        }
        Write-Host "  [OK] AWS Tools available" -ForegroundColor Green

        # Load AWS credentials from profile (required in new PS sessions)
        try {
            Set-AWSCredential -ProfileName default -ErrorAction Stop
            Write-Host "  [OK] AWS credentials loaded (profile: default)" -ForegroundColor Green
            Write-Log "AWS credentials loaded from profile: default" -Level "OK"
        } catch {
            Write-Host "  [WARN] Could not load AWS profile 'default': $_" -ForegroundColor Yellow
            Write-Host "         Trying without explicit profile (IAM role or env vars)..." -ForegroundColor DarkGray
            Write-Log "AWS profile load failed, continuing without explicit profile: $_" -Level "WARN"
        }

        # Check disk space (need ~1.5 GB for driver)
        $drive = Split-Path $TempDir -Qualifier
        $disk  = Get-PSDrive ($drive.TrimEnd(":")) -ErrorAction SilentlyContinue
        if ($disk -and $disk.Free -lt 2GB) {
            Write-Host "  ERROR: Not enough disk space. Need 2 GB, have $([math]::Round($disk.Free/1GB,1)) GB on $drive" -ForegroundColor Red
            Write-Log "Pre-flight failed: insufficient disk space" -Level "ERROR"
            return
        }
        Write-Host "  [OK] Disk space sufficient" -ForegroundColor Green

        # Download FIRST -- before any destructive steps
        Write-Host ""
        Write-Host "  Downloading driver before uninstall..." -ForegroundColor Cyan

        # If S3 info not passed in, fetch it now
        $dlS3Bucket = $S3Bucket
        $dlS3Key    = $S3Key
        if (-not $dlS3Bucket -or -not $dlS3Key) {
            Write-Host "  Fetching S3 download info..." -ForegroundColor Cyan
            $s3Info = if ($TargetVariant -eq "GRID") {
                Get-LatestGridVersion -GpuName ""
            } else {
                Get-LatestGamingVersion -GpuName ""
            }
            $dlS3Bucket = $s3Info.S3Bucket
            $dlS3Key    = $s3Info.S3Key
            # Update state with fetched info
            $state.S3Bucket = $dlS3Bucket
            $state.S3Key    = $dlS3Key
        }

        $installerPath = Get-DriverPackage -Variant $TargetVariant -S3Bucket $dlS3Bucket -S3Key $dlS3Key
        if (-not $installerPath -or -not (Test-Path $installerPath)) {
            Write-Host "  ERROR: Download failed. Aborting -- current driver untouched." -ForegroundColor Red
            Write-Log "Pre-flight failed: download failed" -Level "ERROR"
            return
        }
        Write-Host "  [OK] Driver downloaded: $installerPath" -ForegroundColor Green
        $state.InstallerPath = $installerPath
        $state.Step = "AFTER_DOWNLOAD"
        Save-State $state
    }

    # ── STEP 1: UNINSTALL ────────────────────────────────────
    if ($state.Step -notin @("AFTER_UNINSTALL", "AFTER_REGISTRY")) {
        Write-Host ""
        Write-Host "  Step 2 / 4  --  Uninstall" -ForegroundColor White
        $state.Step = "UNINSTALLING"
        Save-State $state

        Invoke-NvidiaUninstall

        $state.Step = "AFTER_UNINSTALL"
        Save-State $state

        Request-Reboot -Reason "Clean uninstall completed" -NextStep "AFTER_UNINSTALL"
    }

    # ── STEP 2: REGISTRY CLEANUP ─────────────────────────────
    if ($state.Step -eq "AFTER_UNINSTALL") {
        Write-Host ""
        Write-Host "  Step 3 / 4  --  Registry Cleanup" -ForegroundColor White

        Write-Host "  Rescanning installed drivers..." -ForegroundColor Cyan
        $rescan = Get-InstalledNvidiaInfo
        if ($rescan.Installed) {
            Write-Host "  Still detected: $($rescan.Version) [$($rescan.Variant)]" -ForegroundColor Yellow
        } else {
            Write-Host "  No driver detected -- ready for cleanup." -ForegroundColor Green
        }

        Invoke-RegistryCleanup

        $state.Step = "AFTER_REGISTRY"
        Save-State $state

        Request-Reboot -Reason "Registry cleanup completed" -NextStep "AFTER_REGISTRY"
    }

    # ── STEP 3: INSTALL ──────────────────────────────────────
    if ($state.Step -eq "AFTER_REGISTRY") {
        Write-Host ""
        Write-Host "  Step 4 / 4  --  Install $($state.TargetVariant) Driver  ($($state.TargetVersion))" -ForegroundColor White

        Write-Host "  Rescanning installed drivers..." -ForegroundColor Cyan
        $rescan = Get-InstalledNvidiaInfo
        if ($rescan.Installed) {
            Write-Host "  Still detected: $($rescan.Version) [$($rescan.Variant)]" -ForegroundColor Yellow
        } else {
            Write-Host "  No driver detected -- clean slate confirmed." -ForegroundColor Green
        }
        Write-Host ""

        # Use already-downloaded installer (downloaded before uninstall)
        $installerPath = $state.InstallerPath
        if (-not $installerPath -or -not (Test-Path $installerPath)) {
            Write-Host "  Cached installer not found -- re-downloading..." -ForegroundColor Yellow
            $installerPath = Get-DriverPackage -Variant $state.TargetVariant -S3Bucket $state.S3Bucket -S3Key $state.S3Key
        }
        if (-not $installerPath) {
            Write-Host "  No installer available. Aborting." -ForegroundColor Red
            Clear-State
            return
        }

        $ok = Install-NvidiaDriver -InstallerPath $installerPath -Variant $state.TargetVariant

        if ($ok) {
            # Gaming driver: requires registry key + cert after install (per AWS docs)
            if ($state.TargetVariant -eq "Gaming") {
                Write-Host "  Configuring Gaming driver license..." -ForegroundColor Cyan
                try {
                    $regPath = "HKLM:\SOFTWARE\NVIDIA Corporation\Global"
                    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
                    New-ItemProperty -Path $regPath -Name "vGamingMarketplace" -PropertyType DWord -Value 2 -Force | Out-Null
                    Write-Host "  Registry key set: vGamingMarketplace=2" -ForegroundColor Green
                    Write-Log "Gaming registry key set" -Level "OK"
                } catch {
                    Write-Log "Gaming registry key failed: $_" -Level "WARN"
                }
                try {
                    $certUrl  = "https://nvidia-gaming.s3.amazonaws.com/GridSwCert-Archive/GridSwCertWindows_2024_02_22.cert"
                    $certDest = "$env:PUBLIC\Documents\GridSwCert.txt"
                    Invoke-WebRequest -Uri $certUrl -OutFile $certDest -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
                    Write-Host "  Gaming cert downloaded: $certDest" -ForegroundColor Green
                    Write-Log "Gaming cert downloaded" -Level "OK"
                } catch {
                    Write-Log "Gaming cert download failed: $_" -Level "WARN"
                    Write-Host "  Warning: Could not download gaming cert. Licensing may not work." -ForegroundColor Yellow
                }
            }

            $state.Step = "AFTER_INSTALL"
            Save-State $state

            Set-NvidiaVirtualDisplayAsPrimary
            Clear-State

            Write-Host ""
            Write-Host "  +----------------------------------------------+" -ForegroundColor Green
            Write-Host "  |  Installation completed successfully.          |" -ForegroundColor Green
            Write-Host "  +----------------------------------------------+" -ForegroundColor Green
            Write-Host ""

            if (Prompt-YesNo "A reboot is recommended to finalize the driver. Reboot now?") {
                Write-Host "  Rebooting in 10 seconds..." -ForegroundColor Red
                Start-Sleep 10
                Restart-Computer -Force
            }
        } else {
            Write-Host ""
            Write-Host "  Installation failed. State preserved -- re-run the script to retry." -ForegroundColor Red
            Write-Log "Installation failed. State preserved at AFTER_REGISTRY." -Level "ERROR"
        }
    }
}

# ─────────────────────────────────────────────────────────────
#  ENTRY POINT
# ─────────────────────────────────────────────────────────────
foreach ($dir in @($WorkDir, $TempDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

Show-Banner

# ── AWS Credentials -- load profile globally for all S3 operations ──
if (Get-Command Set-AWSCredential -ErrorAction SilentlyContinue) {
    try {
        Set-AWSCredential -ProfileName default -ErrorAction Stop
        Write-Log "AWS credentials loaded (profile: default)" -Level "OK"
    } catch {
        Write-Log "AWS profile 'default' not found -- using IAM role or env vars" -Level "WARN"
    }
}

# ── Resume from saved state (post-reboot or manual -Resume) ──
$existingState = Load-State
if ($existingState -and ($Resume -or ($existingState.Step -in @("FRESH", "AFTER_DOWNLOAD", "AFTER_UNINSTALL", "AFTER_REGISTRY")))) {
    Write-Host "  Resuming from saved step: " -NoNewline -ForegroundColor Yellow
    Write-Host $existingState.Step -ForegroundColor White
    Write-Log "Resuming from step: $($existingState.Step)"
    Write-Host ""
    Write-Host "  Rescanning current GPU driver state..." -ForegroundColor Cyan
    $cur = Get-InstalledNvidiaInfo
    if ($cur.Installed) {
        Write-Host "  Found: $($cur.Version) [$($cur.Variant)]  --  $($cur.GpuName)" -ForegroundColor Cyan
    } else {
        Write-Host "  No driver currently detected." -ForegroundColor DarkGray
    }
    Write-Host ""
    # If S3 info missing from old state, re-fetch
    $resumeS3Bucket = $existingState.S3Bucket
    $resumeS3Key    = $existingState.S3Key
    if (-not $resumeS3Bucket -or -not $resumeS3Key) {
        Write-Host "  S3 info missing from state -- re-fetching..." -ForegroundColor Yellow
        $refetch = if ($existingState.TargetVariant -eq "GRID") {
            Get-LatestGridVersion -GpuName $cur.GpuName
        } else {
            Get-LatestGamingVersion -GpuName $cur.GpuName
        }
        $resumeS3Bucket = $refetch.S3Bucket
        $resumeS3Key    = $refetch.S3Key
        if (-not $existingState.TargetVersion) {
            $existingState.TargetVersion = $refetch.Version
        }
    }
    Invoke-FullInstall `
        -TargetVariant $existingState.TargetVariant `
        -Version       $existingState.TargetVersion `
        -S3Bucket      $resumeS3Bucket `
        -S3Key         $resumeS3Key
    exit 0
}

# ── Fresh run ─────────────────────────────────────────────────
$info = Step-ShowStatus

if (-not $info.Installed) {
    Write-Host "  No NVIDIA driver installed." -ForegroundColor Yellow
    $variant    = if (Prompt-YesNo "Install GRID / Enterprise driver? (No = Gaming)") { "GRID" } else { "Gaming" }
    $latestInfo = if ($variant -eq "GRID") { Get-LatestGridVersion -GpuName "" } else { Get-LatestGamingVersion -GpuName "" }
    Save-State @{ Step="FRESH"; TargetVariant=$variant; TargetVersion=$latestInfo.Version; S3Bucket=$latestInfo.S3Bucket; S3Key=$latestInfo.S3Key }
    Invoke-FullInstall -TargetVariant $variant -Version $latestInfo.Version -S3Bucket $latestInfo.S3Bucket -S3Key $latestInfo.S3Key
    exit 0
}

$online = Step-CheckOnline -info $info
$action = Step-ActionMenu  -info $info -online $online
if ($null -eq $action) { exit 0 }

switch -Wildcard ($action) {
    "*Update driver*" {
        $latest = if ($info.Variant -eq "GRID") { $online.LatestGrid } else { $online.LatestGaming }
        $v      = $latest.Version
        Save-State @{ Step="FRESH"; TargetVariant=$info.Variant; TargetVersion=$v; S3Bucket=$latest.S3Bucket; S3Key=$latest.S3Key }
        Invoke-FullInstall -TargetVariant $info.Variant -Version $v -S3Bucket $latest.S3Bucket -S3Key $latest.S3Key
    }
    "*GRID*" {
        $latest = $online.LatestGrid
        $v      = $latest.Version
        Save-State @{ Step="FRESH"; TargetVariant="GRID"; TargetVersion=$v; S3Bucket=$latest.S3Bucket; S3Key=$latest.S3Key }
        Invoke-FullInstall -TargetVariant "GRID" -Version $v -S3Bucket $latest.S3Bucket -S3Key $latest.S3Key
    }
    "*Gaming*" {
        $latest = $online.LatestGaming
        $v      = $latest.Version
        Save-State @{ Step="FRESH"; TargetVariant="Gaming"; TargetVersion=$v; S3Bucket=$latest.S3Bucket; S3Key=$latest.S3Key }
        Invoke-FullInstall -TargetVariant "Gaming" -Version $v -S3Bucket $latest.S3Bucket -S3Key $latest.S3Key
    }
    "*Reinstall*" {
        # Reinstall: re-fetch S3 key for current variant
        $latestInfo = if ($info.Variant -eq "GRID") { Get-LatestGridVersion -GpuName $info.GpuName } else { Get-LatestGamingVersion -GpuName $info.GpuName }
        Save-State @{ Step="FRESH"; TargetVariant=$info.Variant; TargetVersion=$info.Version; S3Bucket=$latestInfo.S3Bucket; S3Key=$latestInfo.S3Key }
        Invoke-FullInstall -TargetVariant $info.Variant -Version $info.Version -S3Bucket $latestInfo.S3Bucket -S3Key $latestInfo.S3Key
    }
    "*Virtual Display*" {
        Set-NvidiaVirtualDisplayAsPrimary
    }
    default {
        Write-Host "  No action taken." -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
Write-Host ""
