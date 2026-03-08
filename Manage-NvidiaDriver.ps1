#Requires -RunAsAdministrator
<#
.SYNOPSIS
    airgpu Driver Manager -- NVIDIA driver management for Windows 11.

.DESCRIPTION
    - Detects installed NVIDIA driver (version, variant, GPU model)
    - Checks latest versions from official AWS S3 buckets
    - Supports variant switching: Gaming <-> GRID
    - Downloads driver BEFORE uninstall (safe -- aborts if download fails)
    - Clean uninstall + registry cleanup, single reboot, then install

.NOTES
    Run as Administrator. Requires AWS Tools for PowerShell (S3 access).
    Working dir : C:\Program Files\airgpu\Driver Manager\
    Log file    : C:\Program Files\airgpu\Driver Manager\driver_manager.log
#>

param([switch]$Resume)

# -------------------------------------------------------------
#  CONFIGURATION
# -------------------------------------------------------------
$WorkDir      = "C:\Program Files\airgpu\Driver Manager"
$DownloadDir  = "$WorkDir\Downloads"
$StateFile    = "$WorkDir\state.json"
$LogFile      = "$WorkDir\driver_manager.log"
$RunKey       = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$RunName      = "airgpuDriverManagerResume"
$ScriptPath   = $MyInvocation.MyCommand.Path
$ExePath      = "C:\Program Files\airgpu\airgpu-driver-manager.exe"
$AwsCredsFile = "$env:USERPROFILE\.aws\credentials"

# -------------------------------------------------------------
#  LOGGING  (moderate -- key events only, no per-registry-key spam)
# -------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    # Only print to console for WARN/ERROR (INFO goes to log file only)
    switch ($Level) {
        "ERROR" { Write-Host "  [ERROR] $Message" -ForegroundColor Red }
        "WARN"  { Write-Host "  [WARN]  $Message" -ForegroundColor Yellow }
        "OK"    { Write-Host "  [OK]    $Message" -ForegroundColor Green }
    }
}

function Write-Status {
    param([string]$Message, [string]$Color = "White")
    Write-Host "  $Message" -ForegroundColor $Color
}

# -------------------------------------------------------------
#  SPINNER  (Braille, runs in runspace, call Stop-Spinner to end)
# -------------------------------------------------------------
function Start-Spinner {
    param([string]$Label = "Working")
    $flag = [System.Collections.Generic.List[bool]]::new(); $flag.Add($false)
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace(); $rs.Open()
    $rs.SessionStateProxy.SetVariable('stopFlag', $flag)
    $rs.SessionStateProxy.SetVariable('label', $Label)
    $psh = [System.Management.Automation.PowerShell]::Create(); $psh.Runspace = $rs
    $psh.AddScript({
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $frames = [char[]]@(0x280B,0x2819,0x2839,0x2838,0x283C,0x2834,0x2826,0x2827,0x2807,0x280F)
        $i = 0
        while (-not $stopFlag[0]) {
            [Console]::Write("`r  $label  " + $frames[$i % $frames.Count] + "  ")
            Start-Sleep -Milliseconds 80; $i++
        }
    }) | Out-Null
    $h = $psh.BeginInvoke()
    return @{ Psh=$psh; Rs=$rs; Handle=$h; Flag=$flag }
}
function Stop-Spinner {
    param($ctx, [string]$Done = "", [string]$Color = "Green")
    $ctx.Flag[0] = $true; Start-Sleep -Milliseconds 150
    $ctx.Psh.EndInvoke($ctx.Handle) | Out-Null
    $ctx.Psh.Dispose(); $ctx.Rs.Close()
    if ($Done) { Write-Host "`r  $Done                              " -ForegroundColor $Color }
    else        { Write-Host "`r                                      " -NoNewline }
}

# -------------------------------------------------------------
#  PROGRESS BAR  (block chars for download)
# -------------------------------------------------------------
function Write-ProgressBar {
    param([long]$Current, [long]$Total, [string]$Label = "Downloading")
    if ($Total -le 0) { return }
    $pct   = [math]::Min(100, [int]($Current * 100 / $Total))
    $width = 30
    $filled = [math]::Round($width * $pct / 100)
    $bar   = ([string][char]0x2593 * $filled) + ([string][char]0x2591 * ($width - $filled))
    $curMB = [math]::Round($Current / 1MB, 0)
    $totMB = [math]::Round($Total   / 1MB, 0)
    [Console]::Write("`r  $Label  $bar  $pct%  $curMB / $totMB MB   ")
}

# -------------------------------------------------------------
#  AWS CREDENTIALS
#  Uses SharedCredentialsFile explicitly to avoid conflict with
#  empty NetSDKCredentialsFile profile of the same name.
# -------------------------------------------------------------
function Set-AwsCredentials {
    if (Get-Command Set-AWSCredential -ErrorAction SilentlyContinue) {
        if (Test-Path $AwsCredsFile) {
            try {
                # Read key/secret directly from credentials file -- avoids parameter set ambiguity
                $ini = Get-Content $AwsCredsFile | Where-Object { $_ -match '=' }
                $kvp = @{}; $ini | ForEach-Object { $k,$v = $_ -split '\s*=\s*',2; $kvp[$k.Trim()] = $v.Trim() }
                $key    = $kvp['aws_access_key_id']
                $secret = $kvp['aws_secret_access_key']
                if ($key -and $secret) {
                    Set-AWSCredential -AccessKey $key -SecretKey $secret -StoreAs default -ErrorAction Stop
                    Set-AWSCredential -ProfileName default -ErrorAction Stop
                    Write-Log "AWS credentials loaded from file" -Level "INFO"
                }
            } catch {
                Write-Log "AWS credentials file could not be loaded: $_" -Level "WARN"
            }
        } else {
            Write-Log "No credentials file -- using IAM instance role" -Level "INFO"
        }
        Set-DefaultAWSRegion -Region "us-east-1" -ErrorAction SilentlyContinue
    }
}

# -------------------------------------------------------------
#  STATE MANAGEMENT
# -------------------------------------------------------------
function Save-State {
    param([hashtable]$State)
    if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
    Write-Log "State: $($State.Step)" -Level "INFO"
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
    Write-Log "State and resume task cleared." -Level "INFO"
}

function Clear-Downloads {
    if (Test-Path $DownloadDir) {
        Remove-Item "$DownloadDir\*" -Force -ErrorAction SilentlyContinue
        Write-Log "Downloads cleared." -Level "INFO"
    }
}

function Register-ResumeOnBoot {
    param([string]$NextStep)
    $state = Load-State
    if ($null -eq $state) { $state = @{} }
    $state.Step = $NextStep
    Save-State $state

    $launchTarget = if (Test-Path $ExePath) { $ExePath } else { "powershell.exe" }
    $launchArgs   = if (Test-Path $ExePath) { "-Resume" } `
                    else { "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Resume" }
    $action    = New-ScheduledTaskAction -Execute $launchTarget -Argument $launchArgs
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
                     -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 60)
    Register-ScheduledTask -TaskName "airgpuDriverManagerResume" -Action $action `
        -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    # Run key as backup
    $runVal = if (Test-Path $ExePath) { "`"$ExePath`" -Resume" } `
              else { "powershell.exe -ExecutionPolicy Bypass -WindowStyle Normal -File `"$ScriptPath`" -Resume" }
    Set-ItemProperty -Path $RunKey -Name $RunName -Value $runVal -ErrorAction SilentlyContinue
    Write-Log "Resume registered for step: $NextStep" -Level "INFO"
}

# -------------------------------------------------------------
#  UI HELPERS
# -------------------------------------------------------------
function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "    ___________  " -NoNewline -ForegroundColor White
    Write-Host ""
    Write-Host "   (  +-------+  )" -ForegroundColor Cyan
    Write-Host "  ( | +-----+ | )" -ForegroundColor Cyan
    Write-Host " (  | |     | |  )   AIRGPU" -ForegroundColor Cyan
    Write-Host " (  | |     | |  )   DRIVER MANAGER" -ForegroundColor DarkCyan
    Write-Host " (  | +-----+ | )" -ForegroundColor Cyan
    Write-Host "  (  +-------+  )" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Section { param([string]$T)
    Write-Host ""; Write-Host "  -- $T " -ForegroundColor DarkGray; Write-Host "" }

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

# -------------------------------------------------------------
#  STATE DIALOG
#  Shown on startup when a saved state exists.
#  Options: Resume | Start over | Clean up & exit
# -------------------------------------------------------------
function Show-StateDialog {
    param([hashtable]$State)
    $stepLabel = switch ($State.Step) {
        "AFTER_DOWNLOAD"  { "Waiting to uninstall  (driver already downloaded)" }
        "AFTER_UNINSTALL" { "Waiting to install  (uninstall done, reboot completed)" }
        "AFTER_REGISTRY"  { "Waiting to install  (registry cleaned, reboot completed)" }
        default           { $State.Step }
    }
    $targetLine = ("  |  Target  : " + $State.TargetVariant + " " + $State.TargetVersion).PadRight(52) + "|"
    $stepLine   = ("  |  Step    : " + $stepLabel).PadRight(52) + "|"
    Write-Host ""
    Write-Host "  +---------------------------------------------------+" -ForegroundColor Yellow
    Write-Host "  |  Saved state found                              |" -ForegroundColor Yellow
    Write-Host $targetLine -ForegroundColor Yellow
    Write-Host $stepLine   -ForegroundColor Yellow
    Write-Host "  +---------------------------------------------------+" -ForegroundColor Yellow
    Write-Host ""

    $sel = Prompt-Menu "What would you like to do?" @(
        "Resume from saved step  ($($State.Step))",
        "Start over  (clear state, keep downloaded files)",
        "Clean up everything  (clear state + downloads) and exit"
    )

    switch ($sel) {
        1 { return "resume" }
        2 { Clear-State; return "fresh" }
        3 { Clear-State; Clear-Downloads; Write-Status "Cleaned up. Exiting." "Green"; exit 0 }
        0 { Write-Status "Cancelled." "DarkGray"; exit 0 }
    }
}

# -------------------------------------------------------------
#  GPU DETECTION
# -------------------------------------------------------------
function Get-InstalledNvidiaInfo {
    $info = @{ Installed=$false; Version=""; Variant="Unknown"; GpuName=""; DriverDate="" }

    $gpu = Get-WmiObject Win32_VideoController |
        Where-Object { $_.Name -like "*NVIDIA*" -or $_.AdapterCompatibility -like "*NVIDIA*" } |
        Select-Object -First 1
    if (-not $gpu) { return $info }

    $info.GpuName    = $gpu.Name
    $info.DriverDate = $gpu.DriverDate
    $info.Version    = if ($gpu.DriverVersion -match '(\d{3})(\d{2})$') { "$($Matches[1]).$($Matches[2])" }
                       else { $gpu.DriverVersion }

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

    $vGaming = (Get-ItemProperty "HKLM:\SOFTWARE\NVIDIA Corporation\Global" -Name "vGamingMarketplace" -ErrorAction SilentlyContinue).vGamingMarketplace

    if     ($vGaming -eq 2)                                                              { $info.Variant = "Gaming" }
    elseif ($names -match "GRID|vGPU|Virtual GPU|Tesla|Enterprise")                     { $info.Variant = "GRID" }
    elseif ($names -match "GeForce|Game Ready|Gaming|Studio")               { $info.Variant = "Gaming" }
    elseif ($info.GpuName -match "Tesla|A10|A100|T4|V100|K80|A10G|L4|L40") { $info.Variant = "GRID" }
    else {
        $repoPath = "$env:SystemRoot\System32\DriverStore\FileRepository"
        if     (Get-ChildItem $repoPath -Filter "nvgridswgame*" -ErrorAction SilentlyContinue) { $info.Variant = "Gaming" }
        elseif (Get-ChildItem $repoPath -Filter "nvgridsw_aws*" -ErrorAction SilentlyContinue) { $info.Variant = "GRID" }
        else   { $info.Variant = "Unknown" }
    }
    return $info
}

# -------------------------------------------------------------
#  S3 VERSION CHECK
#  Gaming : s3://nvidia-gaming/windows/latest/
#  GRID   : s3://ec2-windows-nvidia-drivers/latest/
# -------------------------------------------------------------
function Get-S3DriverInfo {
    param([string]$Bucket, [string]$Prefix)
    try {
        $exe = Get-S3Object -BucketName $Bucket -KeyPrefix $Prefix -Region "us-east-1" -ErrorAction Stop |
            Where-Object { $_.Key -like "*.exe" } | Select-Object -First 1
        if ($exe -and (Split-Path $exe.Key -Leaf) -match '(\d+\.\d+)') {
            return @{ Version=$Matches[1]; S3Key=$exe.Key; S3Bucket=$Bucket }
        }
    } catch { Write-Log "S3 lookup failed ($Bucket): $_" -Level "WARN" }
    return @{ Version="Unknown"; S3Key=""; S3Bucket="" }
}

function Get-LatestGamingVersion {
    return Get-S3DriverInfo -Bucket "nvidia-gaming" -Prefix "windows/latest/"
}

function Test-GamingDriverSupported {
    param([string]$GpuName)
    # Gaming driver supported on: T4 (G4dn), A10G (G5), L4 (G6), L40S (G6e)
    # NOT supported on fractal variants: L4f, L4s etc. (G6f)
    if ($GpuName -match '(?i)\bT4\b')                                             { return $true }
    if ($GpuName -match '(?i)\bA10G\b')                                           { return $true }
    if ($GpuName -match '(?i)\bL40S\b')                                           { return $true }
    if ($GpuName -match '(?i)\bL4\b' -and $GpuName -notmatch '(?i)\bL4[a-z]+') { return $true }
    return $false
}

function Get-LatestGridVersion {
    return Get-S3DriverInfo -Bucket "ec2-windows-nvidia-drivers" -Prefix "latest/"
}

# -------------------------------------------------------------
#  UNINSTALL
# -------------------------------------------------------------
function Invoke-NvidiaUninstall {
    Write-Log "Uninstall started" -Level "INFO"
    $spinCtx = Start-Spinner -Label "Uninstalling"

    # Registered entries
    $apps = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*NVIDIA*" -and $_.UninstallString }

    foreach ($app in $apps) {
        Write-Log "Uninstalling: $($app.DisplayName)" -Level "INFO"
        try {
            if ($app.UninstallString -match "MsiExec") {
                $guid = [regex]::Match($app.UninstallString, '\{[^}]+\}').Value
                if ($guid) { Start-Process msiexec.exe -ArgumentList "/x $guid /quiet /norestart" -Wait -NoNewWindow }
            } elseif ($app.UninstallString -match "\.exe") {
                $exe = [regex]::Match($app.UninstallString, '"?([^"]+\.exe)"?').Groups[1].Value
                if ($exe -and (Test-Path $exe)) { Start-Process $exe -ArgumentList "-s -noreboot" -Wait -NoNewWindow }
            }
        } catch { Write-Log "Failed to uninstall '$($app.DisplayName)': $_" -Level "WARN" }
    }

    # NVI2.EXE / setup.exe for display driver
    $setup = Get-ChildItem "$env:ProgramFiles\NVIDIA Corporation\Installer2\InstallerCore" `
                 -Filter "NVI2.EXE" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $setup) {
        $setup = Get-ChildItem "$env:SystemRoot\System32\DriverStore\FileRepository" `
                     -Recurse -Filter "setup.exe" -ErrorAction SilentlyContinue |
                     Where-Object { $_.FullName -like "*nv*" } | Select-Object -First 1
    }
    if ($setup) {
        Write-Log "Running display driver uninstaller" -Level "INFO"
        try { Start-Process $setup.FullName -ArgumentList "-s -noreboot -clean" -Wait -NoNewWindow }
        catch { Write-Log "Display driver uninstall failed: $_" -Level "WARN" }
    } else {
        $list = pnputil /enum-drivers 2>&1
        [regex]::Matches($list, 'oem\d+\.inf') | Select-Object -ExpandProperty Value -Unique | ForEach-Object {
            if ($list -match "$_[\s\S]{0,200}nv[a-z]") {
                pnputil /delete-driver $_ /uninstall /force 2>&1 | Out-Null
            }
        }
    }

    Write-Log "Stopping NVIDIA services" -Level "INFO"
    Get-Service | Where-Object { $_.Name -like "nv*" -or $_.DisplayName -like "*NVIDIA*" } | ForEach-Object {
        Stop-Service $_.Name -Force -ErrorAction SilentlyContinue
        sc.exe delete $_.Name 2>&1 | Out-Null
    }

    @("$env:ProgramFiles\NVIDIA Corporation","$env:ProgramFiles\NVIDIA",
      "${env:ProgramFiles(x86)}\NVIDIA Corporation") |
        ForEach-Object { Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue }
    Get-Item "$env:SystemRoot\System32\DriverStore\FileRepository\nv*" -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    Stop-Spinner -ctx $spinCtx -Done "Uninstall complete." -Color "Green"
    Write-Log "Uninstall complete" -Level "OK"
}

# -------------------------------------------------------------
#  REGISTRY CLEANUP
# -------------------------------------------------------------
function Invoke-RegistryCleanup {
    $keys = @(
        "HKLM:\SOFTWARE\NVIDIA Corporation","HKLM:\SOFTWARE\WOW6432Node\NVIDIA Corporation",
        "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm","HKLM:\SYSTEM\CurrentControlSet\Services\nvpciflt",
        "HKLM:\SYSTEM\CurrentControlSet\Services\nvstor","HKLM:\SYSTEM\CurrentControlSet\Services\NvStreamKms",
        "HKLM:\SYSTEM\CurrentControlSet\Services\NVSvc","HKLM:\SYSTEM\CurrentControlSet\Services\nvvhci",
        "HKLM:\SYSTEM\CurrentControlSet\Services\nvvad_WaveExtensible",
        "HKLM:\SYSTEM\CurrentControlSet\Services\NvTelemetryContainer",
        "HKCU:\SOFTWARE\NVIDIA Corporation"
    )
    $removed = 0
    $keys | ForEach-Object {
        if (Test-Path $_) { Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue; $removed++ }
    }
    @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
      "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall") | ForEach-Object {
        Get-ChildItem $_ -ErrorAction SilentlyContinue |
            Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DisplayName -like "*NVIDIA*" } |
            ForEach-Object { Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue; $removed++ }
    }
    Write-Status "Registry cleanup complete  ($removed keys removed)." "Green"
    Write-Log "Registry cleanup complete ($removed keys removed)" -Level "OK"
}

# -------------------------------------------------------------
#  DOWNLOAD
# -------------------------------------------------------------
function Get-DriverPackage {
    param([string]$Variant, [string]$S3Bucket, [string]$S3Key)
    if (-not (Test-Path $DownloadDir)) { New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null }

    if (-not $S3Bucket -or -not $S3Key) {
        Write-Status "No S3 source available. Enter installer path manually (empty = cancel):" "Yellow"
        $manual = (Read-Host "  Path").Trim('"').Trim()
        if ($manual -and (Test-Path $manual)) { return $manual }
        Write-Log "No installer source available" -Level "ERROR"
        return ""
    }

    $dest = "$DownloadDir\$(Split-Path $S3Key -Leaf)"
    if (Test-Path $dest) {
        Write-Status "Using cached installer: $(Split-Path $dest -Leaf)" "Green"
        return $dest
    }

    Write-Host "  Downloading $(Split-Path $S3Key -Leaf)" -ForegroundColor DarkGray
    Set-AwsCredentials
    try {
        # Get file size for progress bar
        $meta  = Get-S3ObjectMetadata -BucketName $S3Bucket -Key $S3Key -Region "us-east-1" -ErrorAction SilentlyContinue
        $total = if ($meta) { $meta.ContentLength } else { 0 }

        # Download with progress polling
        $tmpDest = $dest + ".part"
        $job = Start-Job -ScriptBlock {
            param($b,$k,$f,$r)
            Import-Module AWSPowerShell -ErrorAction SilentlyContinue
            Copy-S3Object -BucketName $b -Key $k -LocalFile $f -Region $r -ErrorAction Stop | Out-Null
        } -ArgumentList $S3Bucket,$S3Key,$tmpDest,"us-east-1"

        while ($job.State -eq "Running") {
            $cur = if (Test-Path $tmpDest) { (Get-Item $tmpDest).Length } else { 0 }
            Write-ProgressBar -Current $cur -Total $total -Label "Downloading"
            Start-Sleep -Milliseconds 300
        }
        Receive-Job $job -ErrorAction Stop | Out-Null
        Remove-Job $job

        if (Test-Path $tmpDest) { Move-Item $tmpDest $dest -Force }
        $sizeMB = [math]::Round((Get-Item $dest).Length / 1MB, 0)
        Write-Host "`r  $([char]0x2593 * 30)  100%  $sizeMB MB       " -ForegroundColor Green
        Write-Log "Downloaded: $(Split-Path $dest -Leaf) ($sizeMB MB)" -Level "OK"
        return $dest
    } catch {
        if (Test-Path "$dest.part") { Remove-Item "$dest.part" -Force -ErrorAction SilentlyContinue }
        Write-Log "S3 download failed: $_" -Level "ERROR"
        return ""
    }
}

# -------------------------------------------------------------
#  INSTALL
# -------------------------------------------------------------
function Install-NvidiaDriver {
    param([string]$InstallerPath, [string]$Variant)
    if (-not $InstallerPath -or -not (Test-Path $InstallerPath)) {
        Write-Log "Installer not found: $InstallerPath" -Level "ERROR"
        return $false
    }
    Write-Log "Silent install started: $(Split-Path $InstallerPath -Leaf) [$Variant]" -Level "INFO"
    $argList = @("-s","-noreboot","-clean")
    if ($Variant -eq "GRID") { $argList += "-noeula" }
    $color = if($Variant -eq "Gaming"){"Magenta"}else{"Cyan"}
    $spinCtx = Start-Spinner -Label "Installing $Variant driver"
    try {
        $proc = Start-Process -FilePath $InstallerPath -ArgumentList $argList -Wait -PassThru -NoNewWindow
        Stop-Spinner -ctx $spinCtx -Done "Install complete." -Color $color
        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 14) {
            Write-Log "Driver installed successfully (ExitCode: $($proc.ExitCode))" -Level "OK"
            return $true
        }
        Write-Log "Driver installer exited with code $($proc.ExitCode)" -Level "WARN"
        return $true
    } catch {
        Stop-Spinner -ctx $spinCtx
        Write-Log "Installation error: $_" -Level "ERROR"
        return $false
    }
}

function Set-GamingLicense {
    Write-Log "Configuring Gaming driver license" -Level "INFO"
    try {
        $p = "HKLM:\SOFTWARE\NVIDIA Corporation\Global"
        if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
        New-ItemProperty -Path $p -Name "vGamingMarketplace" -PropertyType DWord -Value 2 -Force | Out-Null
        Write-Log "Gaming license: vGamingMarketplace=2 set" -Level "OK"
    } catch { Write-Log "Gaming registry key failed: $_" -Level "WARN" }
    try {
        Invoke-WebRequest -Uri "https://nvidia-gaming.s3.amazonaws.com/GridSwCert-Archive/GridSwCertWindows_2024_02_22.cert" `
            -OutFile "$env:PUBLIC\Documents\GridSwCert.txt" -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        Write-Log "Gaming cert downloaded" -Level "OK"
    } catch {
        Write-Log "Gaming cert download failed (licensing may not work): $_" -Level "WARN"
    }
}

# -------------------------------------------------------------
#  REBOOT
# -------------------------------------------------------------
function Request-Reboot {
    param([string]$Reason, [string]$NextStep)
    Register-ResumeOnBoot -NextStep $NextStep
    Write-Host ""
    Write-Status "Reboot required  ($Reason)" "Yellow"
    Write-Status "Script will resume automatically at login." "DarkGray"
    Write-Host ""
    if (Prompt-YesNo "Reboot now?") {
        Write-Log "Rebooting now. Resume step: $NextStep" -Level "INFO"
        Start-Sleep -Seconds 5
        Restart-Computer -Force
    } else {
        Write-Log "Reboot deferred. Resume step: $NextStep" -Level "INFO"
        Write-Status "Reboot when ready. Resume manually with: -Resume" "DarkGray"
    }
}

# -------------------------------------------------------------
#  STATUS + ONLINE CHECK
# -------------------------------------------------------------
function Step-ShowStatus {
    $info = Get-InstalledNvidiaInfo
    if (-not $info.Installed) {
        Write-Host "  [!] No NVIDIA driver detected." -ForegroundColor Red
        Write-Log "No NVIDIA driver detected" -Level "WARN"
        return $info
    }
    $vc = switch ($info.Variant) { "Gaming"{"Magenta"} "GRID"{"Cyan"} default{"Gray"} }
    Write-Host "  $($info.GpuName)" -ForegroundColor DarkGray
    Write-Host "  $($info.Version)  " -NoNewline -ForegroundColor White
    Write-Host "[$($info.Variant)]" -ForegroundColor $vc
    Write-Host ""
    Write-Log "GPU: $($info.GpuName) | Driver: $($info.Version) | Variant: $($info.Variant) | Date: $($info.DriverDate)" -Level "INFO"
    return $info
}

function Step-CheckOnline {
    param($info)
    Write-Host "  Checking for updates..." -ForegroundColor DarkGray
    $spinCtx = Start-Spinner -Label "Checking for updates"
    $latestGaming = Get-LatestGamingVersion
    $latestGrid   = Get-LatestGridVersion
    $updateAvailable = $false
    $updateVersion   = ""
    try {
        $latest = if ($info.Variant -eq "GRID") { $latestGrid.Version } else { $latestGaming.Version }
        if ([Version]$latest -gt [Version]$info.Version) {
            $updateAvailable = $true; $updateVersion = $latest
        }
    } catch {}
    Stop-Spinner -ctx $spinCtx
    Write-Log "Version check -- Installed: $($info.Version) [$($info.Variant)] | Gaming: $($latestGaming.Version) | GRID: $($latestGrid.Version)" -Level "INFO"
    if ($updateAvailable) {
        Write-Host "  $([char]0x2191) Update available: $updateVersion" -ForegroundColor Yellow
    } else {
        Write-Host "  $([char]0x2713) Up to date." -ForegroundColor Green
    }
    Write-Host ""
    return @{ UpdateAvailable=$updateAvailable; LatestGaming=$latestGaming; LatestGrid=$latestGrid }
}

function Step-ActionMenu {
    param($info, $online)
    Show-Section "Available Actions"
    $opts = @()
    if ($online.UpdateAvailable)    { $opts += "Update driver  ($($info.Variant) -> latest)" }
    if ($info.Variant -eq "Gaming") { $opts += "Switch to GRID / Enterprise driver" }
    if ($info.Variant -eq "GRID") {
        if (Test-GamingDriverSupported -GpuName $info.GpuName) {
            $opts += "Switch to Gaming / GeForce driver"
        } else {
            $opts += "Switch to Gaming / GeForce driver  [not available for $($info.GpuName)]"
        }
    }
    if (-not $online.UpdateAvailable) { $opts += "Reinstall current driver  ($($info.Version))" }
    $opts += "Show status only  (no changes)"
    $sel = Prompt-Menu "What would you like to do?" $opts
    if ($sel -eq 0) { Write-Status "Cancelled." "DarkGray"; return $null }
    return $opts[$sel - 1]
}

# -------------------------------------------------------------
#  FULL INSTALL FLOW
#
#  Steps: FRESH -> AFTER_DOWNLOAD -> AFTER_UNINSTALL_AND_CLEANUP -> done
#  Only ONE reboot required (after uninstall + registry cleanup combined).
# -------------------------------------------------------------
function Invoke-FullInstall {
    param([string]$TargetVariant, [string]$Version, [string]$S3Bucket = "", [string]$S3Key = "")

    $state = Load-State
    if ($null -eq $state) { $state = @{} }
    $state.TargetVariant = $TargetVariant
    $state.TargetVersion = $Version
    $state.S3Bucket      = $S3Bucket
    $state.S3Key         = $S3Key

    # -- STEP 1: PRE-FLIGHT + DOWNLOAD ------------------------
    if ($state.Step -notin @("AFTER_DOWNLOAD","AFTER_UNINSTALL_AND_CLEANUP")) {
        Write-Host ""; Write-Host "  Step 1 / 3  --  Pre-flight & Download" -ForegroundColor White

        if (-not (Get-Command Get-S3Object -ErrorAction SilentlyContinue)) {
            Write-Status "ERROR: AWS Tools for PowerShell not installed." "Red"
            Write-Status "Run: Install-Module -Name AWSPowerShell -Force -AllowClobber" "Yellow"
            Write-Log "Pre-flight failed: AWS Tools not installed" -Level "ERROR"
            return
        }
        Write-Log "Pre-flight: AWS Tools available" -Level "INFO"

        $disk = Get-PSDrive ((Split-Path $DownloadDir -Qualifier).TrimEnd(":")) -ErrorAction SilentlyContinue
        if ($disk -and $disk.Free -lt 2GB) {
            Write-Status "ERROR: Not enough disk space ($([math]::Round($disk.Free/1GB,1)) GB free, need 2 GB)" "Red"
            Write-Log "Pre-flight failed: insufficient disk space" -Level "ERROR"
            return
        }
        Write-Log "Pre-flight: Disk space sufficient ($([math]::Round($disk.Free/1GB,1)) GB free)" -Level "INFO"

        # Resolve S3 info if not supplied
        $dlBucket = $S3Bucket; $dlKey = $S3Key
        if (-not $dlBucket -or -not $dlKey) {
            $s3 = if ($TargetVariant -eq "GRID") { Get-LatestGridVersion } else { Get-LatestGamingVersion }
            $dlBucket = $s3.S3Bucket; $dlKey = $s3.S3Key
            $state.S3Bucket = $dlBucket; $state.S3Key = $dlKey
        }

        $installer = Get-DriverPackage -Variant $TargetVariant -S3Bucket $dlBucket -S3Key $dlKey
        if (-not $installer -or -not (Test-Path $installer)) {
            Write-Status "Download failed. Current driver untouched." "Red"
            Write-Log "Pre-flight failed: download failed" -Level "ERROR"
            return
        }
        Write-Status "[OK] Driver ready: $(Split-Path $installer -Leaf)" "Green"
        $state.InstallerPath = [string]$installer
        $state.Step = "AFTER_DOWNLOAD"
        Save-State $state
    }

    # -- STEP 2: UNINSTALL + REGISTRY CLEANUP (combined, 1 reboot) --
    if ($state.Step -eq "AFTER_DOWNLOAD") {
        Write-Host ""; Write-Host "  Step 2 / 3  --  Uninstall & Registry Cleanup" -ForegroundColor White
        $state.Step = "UNINSTALLING"; Save-State $state
        Invoke-NvidiaUninstall
        Invoke-RegistryCleanup
        $state.Step = "AFTER_UNINSTALL_AND_CLEANUP"; Save-State $state
        Request-Reboot -Reason "Uninstall + registry cleanup completed" -NextStep "AFTER_UNINSTALL_AND_CLEANUP"
    }

    # -- STEP 3: INSTALL ---------------------------------------
    if ($state.Step -eq "AFTER_UNINSTALL_AND_CLEANUP") {
        Write-Host ""; Write-Host "  Step 3 / 3  --  Install $($state.TargetVariant) Driver ($($state.TargetVersion))" -ForegroundColor White

        $installer = [string]$state.InstallerPath
        if (-not $installer -or -not (Test-Path $installer)) {
            Write-Status "Cached installer missing -- re-downloading..." "Yellow"
            Write-Log "Installer missing from cache, re-downloading" -Level "WARN"
            $installer = Get-DriverPackage -Variant $state.TargetVariant -S3Bucket $state.S3Bucket -S3Key $state.S3Key
        }
        if (-not $installer -or -not (Test-Path $installer)) {
            Write-Status "No installer available. Cannot continue." "Red"
            Write-Log "Install aborted: no installer available" -Level "ERROR"
            Write-Host ""
            Write-Status "State preserved. Re-run to retry." "Yellow"
            return
        }

        $ok = Install-NvidiaDriver -InstallerPath $installer -Variant $state.TargetVariant

        if ($ok) {
            if ($state.TargetVariant -eq "Gaming") { Set-GamingLicense }
            Clear-State
            # Cleanup: remove downloaded installer + downloads folder
            try {
                if (Test-Path $DownloadDir) { Remove-Item $DownloadDir -Recurse -Force -ErrorAction SilentlyContinue }
                Write-Log "Downloads cleaned up" -Level "INFO"
            } catch { Write-Log "Cleanup warning: $_" -Level "WARN" }
            # Remove script (EXE will re-download fresh next run)
            $selfScript = $MyInvocation.ScriptName
            Write-Host ""
            Write-Host "  Done. Driver installed successfully." -ForegroundColor Green
            Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
            Write-Host ""
            Write-Log "Installation completed successfully. Downloads cleaned." -Level "OK"
            if (Prompt-YesNo "Reboot now to finalize driver?") {
                Start-Sleep -Seconds 3; Restart-Computer -Force
            }
            # Remove script after reboot prompt (EXE downloads fresh next time)
            if (Test-Path $selfScript) {
                Start-Sleep -Milliseconds 500
                Remove-Item $selfScript -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Host ""
            Write-Status "Installation failed. State preserved -- re-run to retry." "Red"
            Write-Log "Installation failed. State preserved at AFTER_UNINSTALL_AND_CLEANUP." -Level "ERROR"
        }
    }
}

# -------------------------------------------------------------
#  ENTRY POINT
# -------------------------------------------------------------
foreach ($dir in @($WorkDir,$DownloadDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

Show-Banner

# -- Loading Prerequisites (Braille spinner via runspace) ----
$stopFlag = [System.Collections.Generic.List[bool]]::new()
$stopFlag.Add($false)
$rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
$rs.Open()
$rs.SessionStateProxy.SetVariable('stopFlag', $stopFlag)
$ps = [System.Management.Automation.PowerShell]::Create()
$ps.Runspace = $rs
$ps.AddScript({
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $frames = [char[]]@(0x280B,0x2819,0x2839,0x2838,0x283C,0x2834,0x2826,0x2827,0x2807,0x280F)
    $i = 0
    while (-not $stopFlag[0]) {
        [Console]::Write("`r  Loading...  " + $frames[$i % $frames.Count] + "  ")
        Start-Sleep -Milliseconds 80
        $i++
    }
}) | Out-Null
$handle = $ps.BeginInvoke()
Set-AwsCredentials
$stopFlag[0] = $true
Start-Sleep -Milliseconds 150
$ps.EndInvoke($handle) | Out-Null
$ps.Dispose(); $rs.Close()
Write-Host "`r  Ready.                    " -ForegroundColor Green

# -- Check for saved state -------------------------------------
$existingState = Load-State

if ($existingState -and $existingState.Step -in @("AFTER_DOWNLOAD","AFTER_UNINSTALL_AND_CLEANUP","UNINSTALLING")) {
    $resumeAction = "resume"
}

if ($resumeAction -eq "resume") {
    Write-Host ""
    Write-Status "Resuming from step: $($existingState.Step)" "Yellow"
    Write-Log "Resuming from step: $($existingState.Step)" -Level "INFO"
    $cur = Get-InstalledNvidiaInfo
    Write-Status "Current: $(if($cur.Installed){"$($cur.Version) [$($cur.Variant)] -- $($cur.GpuName)"}else{"No driver detected."})" "Cyan"
    Write-Host ""
    $rBucket = $existingState.S3Bucket; $rKey = $existingState.S3Key
    if (-not $rBucket -or -not $rKey) {
        Write-Status "S3 info missing -- re-fetching..." "Yellow"
        $rf = if ($existingState.TargetVariant -eq "GRID") { Get-LatestGridVersion } else { Get-LatestGamingVersion }
        $rBucket = $rf.S3Bucket; $rKey = $rf.S3Key
        if (-not $existingState.TargetVersion) { $existingState.TargetVersion = $rf.Version }
    }
    Invoke-FullInstall -TargetVariant $existingState.TargetVariant -Version $existingState.TargetVersion `
        -S3Bucket $rBucket -S3Key $rKey
    exit 0
}

# -- Fresh run -------------------------------------------------
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
        if ($action -like "*not available*") {
            Write-Status "Gaming driver is not supported on $($info.GpuName)." "Red"
            Write-Status "Supported GPUs: T4, A10G, L4, L40S (standard instances only)." "Yellow"
        } else {
            $s3 = $online.LatestGaming
            Save-State @{ Step="FRESH"; TargetVariant="Gaming"; TargetVersion=$s3.Version; S3Bucket=$s3.S3Bucket; S3Key=$s3.S3Key }
            Invoke-FullInstall -TargetVariant "Gaming" -Version $s3.Version -S3Bucket $s3.S3Bucket -S3Key $s3.S3Key
        }
    }
    "*Reinstall*" {
        $s3 = if ($info.Variant -eq "GRID") { Get-LatestGridVersion } else { Get-LatestGamingVersion }
        Save-State @{ Step="FRESH"; TargetVariant=$info.Variant; TargetVersion=$info.Version; S3Bucket=$s3.S3Bucket; S3Key=$s3.S3Key }
        Invoke-FullInstall -TargetVariant $info.Variant -Version $info.Version -S3Bucket $s3.S3Bucket -S3Key $s3.S3Key
    }
    default             { Write-Status "No action taken." "DarkGray" }
}

