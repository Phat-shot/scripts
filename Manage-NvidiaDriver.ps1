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
$script:S3CacheGaming = $null   # cached per session
$script:S3CacheGrid   = $null

# -------------------------------------------------------------
#  LOGGING  (moderate -- key events only, no per-registry-key spam)
# -------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    # Only print to console for WARN/ERROR (INFO goes to log file only)
    switch ($Level) {
        "ERROR" { Write-Host "  [!] $Message" -ForegroundColor Red }
        "WARN"  { Write-Host "  [!] $Message" -ForegroundColor Yellow }
        # OK and INFO: log file only
    }
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
    else        { Write-Host "`r                                      " }
    [Console]::Out.Flush()
}


# -------------------------------------------------------------
#  AWS CREDENTIALS
#  Uses SharedCredentialsFile explicitly to avoid conflict with
#  empty NetSDKCredentialsFile profile of the same name.
# -------------------------------------------------------------
$script:AwsCredentialsLoaded = $false
function Set-AwsCredentials {
    if ($script:AwsCredentialsLoaded) { return }   # only run once per session
    if (-not (Get-Command Set-AWSCredential -ErrorAction SilentlyContinue)) { return }

    if (Test-Path $AwsCredsFile) {
        try {
            $ini = Get-Content $AwsCredsFile | Where-Object { $_ -match '^\s*\w' -and $_ -match '=' }
            $kvp = @{}
            $ini | ForEach-Object {
                $parts = $_ -split '\s*=\s*', 2
                if ($parts.Count -eq 2) { $kvp[$parts[0].Trim()] = $parts[1].Trim() }
            }
            $key    = $kvp['aws_access_key_id']
            $secret = $kvp['aws_secret_access_key']
            if ($key -and $secret) {
                # Set session-scope credentials directly -- no profile store involved
                Set-AWSCredential -AccessKey $key -SecretKey $secret -ErrorAction Stop
                Write-Log "AWS credentials loaded from file (session scope)" -Level "INFO"
            } else {
                Write-Log "Credentials file found but key/secret missing -- falling back to IAM role" -Level "WARN"
            }
        } catch {
            Write-Log "AWS credentials file error: $_" -Level "WARN"
        }
    } else {
        Write-Log "No credentials file -- using IAM instance role" -Level "INFO"
    }
    Set-DefaultAWSRegion -Region "us-east-1" -ErrorAction SilentlyContinue
    $script:AwsCredentialsLoaded = $true
}

# -------------------------------------------------------------
#  STATE MANAGEMENT
# -------------------------------------------------------------
function Save-State {
    param([hashtable]$State)
    if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8

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
    Write-Host ""
    Write-Host "  AIRGPU " -NoNewline -ForegroundColor White
    Write-Host "DRIVER MANAGER" -ForegroundColor DarkCyan
    Write-Host ""
}


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

# -------------------------------------------------------------
#  GPU DETECTION
# -------------------------------------------------------------
function Get-InstalledNvidiaInfo {
    $info = @{ Installed=$false; Version=""; Variant="Unknown"; GpuName=""; DriverDate="" }

    # Try nvidia-smi first (most accurate, direct from driver)
    $smi = if (Test-Path "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe") {
               "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe" } else { "nvidia-smi" }
    $smiOk = $false
    try {
        $out = & $smi --query-gpu=name,driver_version --format=csv,noheader 2>&1
        if ($LASTEXITCODE -eq 0 -and $out) {
            $p = $out -split ","
            if ($p.Count -ge 2) {
                $info.GpuName = $p[0].Trim()
                $info.Version = $p[1].Trim()
                $smiOk = $true
            }
        }
    } catch { }

    # Fall back to WMI if nvidia-smi unavailable
    if (-not $smiOk) {
        $gpu = Get-CimInstance Win32_VideoController |
            Where-Object { $_.Name -like "*NVIDIA*" -or $_.AdapterCompatibility -like "*NVIDIA*" } |
            Select-Object -First 1
        if (-not $gpu) { return $info }  # no NVIDIA GPU found at all
        $info.GpuName    = $gpu.Name
        $info.DriverDate = $gpu.DriverDate
        $info.Version    = if ($gpu.DriverVersion -match '(\d{3})(\d{2})$') { "$($Matches[1]).$($Matches[2])" }
                           else { $gpu.DriverVersion }
    }

    if (-not $info.GpuName -and -not $info.Version) { return $info }
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
            return @{ Version=$Matches[1]; S3Key=$exe.Key; S3Bucket=$Bucket; Error=$false }
        }
        Write-Log "S3 lookup: no .exe found in $Bucket/$Prefix" -Level "WARN"
        return @{ Version="Unknown"; S3Key=""; S3Bucket=""; Error=$false }
    } catch {
        Write-Log "S3 lookup failed ($Bucket): $_" -Level "WARN"
        return @{ Version="Unknown"; S3Key=""; S3Bucket=""; Error=$true }
    }
}

function Get-LatestGamingVersion {
    if (-not $script:S3CacheGaming) {
        $script:S3CacheGaming = Get-S3DriverInfo -Bucket "nvidia-gaming" -Prefix "windows/latest/"
    }
    return $script:S3CacheGaming
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
    if (-not $script:S3CacheGrid) {
        $script:S3CacheGrid = Get-S3DriverInfo -Bucket "ec2-windows-nvidia-drivers" -Prefix "latest/"
    }
    return $script:S3CacheGrid
}

# -------------------------------------------------------------
#  UNINSTALL
# -------------------------------------------------------------
function Invoke-NvidiaUninstall {
    Write-Log "Uninstall started" -Level "INFO"
    $spinCtx = Start-Spinner -Label "Uninstalling"

    # Kill NVIDIA Desktop Manager + Container before uninstall
    @("nvdm","nvdmui","NVDisplay.Container") | ForEach-Object {
        Get-Process -Name $_ -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    # Remove NVIDIA Control Panel + Desktop Manager AppX packages
    @("NVIDIACorp.NVIDIAControlPanel","NVIDIACorp.NvidiaDisplayContainer") | ForEach-Object {
        $pkg = Get-AppxPackage -Name $_ -AllUsers -ErrorAction SilentlyContinue
        if ($pkg) {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction SilentlyContinue
            Write-Log "Removed AppX: $_" -Level "INFO"
        }
    }


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
                if ($guid) { $proc = Start-Process msiexec.exe -ArgumentList "/x $guid /quiet /norestart" -PassThru -NoNewWindow; if ($proc) { while (-not $proc.HasExited) { Start-Sleep -Milliseconds 500 } } }
            } elseif ($app.UninstallString -match "\.exe") {
                $exe = [regex]::Match($app.UninstallString, '"?([^"]+\.exe)"?').Groups[1].Value
                if ($exe -and (Test-Path $exe)) { $proc = Start-Process $exe -ArgumentList "-s -noreboot" -PassThru -NoNewWindow; if ($proc) { while (-not $proc.HasExited) { Start-Sleep -Milliseconds 500 } } }
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
        try {
            $setupProc = Start-Process $setup.FullName -ArgumentList "-s -noreboot -clean" -PassThru -NoNewWindow
            while (-not $setupProc.HasExited) { Start-Sleep -Milliseconds 500 }
        } catch { Write-Log "Display driver uninstall failed: $_" -Level "WARN" }
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
        $svcName = $_.Name
        try {
            $svc = Get-Service $svcName -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne "Stopped") {
                $svc.Stop(); $svc.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(10))
            }
        } catch { $null }
        sc.exe delete $svcName 2>&1 | Out-Null
    }

    @("$env:ProgramFiles\NVIDIA Corporation","$env:ProgramFiles\NVIDIA",
      "${env:ProgramFiles(x86)}\NVIDIA Corporation") |
        ForEach-Object { Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue }
    Get-Item "$env:SystemRoot\System32\DriverStore\FileRepository\nv*" -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    Stop-Spinner -ctx $spinCtx -Done "Uninstall complete." -Color "Green"
    [Console]::Out.Flush()
    Write-Host ""
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
    Write-Log "Registry cleanup complete ($removed keys removed)" -Level "OK"
}

# -------------------------------------------------------------
#  DOWNLOAD
# -------------------------------------------------------------
function Get-DriverPackage {
    param([string]$Variant, [string]$S3Bucket, [string]$S3Key)
    if (-not (Test-Path $DownloadDir)) { New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null }

    if (-not $S3Bucket -or -not $S3Key) {
        Write-Host "  No S3 source available. Enter installer path manually (empty = cancel):" -ForegroundColor Yellow
        $manual = (Read-Host "  Path").Trim('"').Trim()
        if ($manual -and (Test-Path $manual)) { return $manual }
        Write-Log "No installer source available" -Level "ERROR"
        return ""
    }

    $dest = "$DownloadDir\$(Split-Path $S3Key -Leaf)"
    if (Test-Path $dest) {
        Write-Host "  Using cached installer: $(Split-Path $dest -Leaf)" -ForegroundColor Green
        return $dest
    }

    $tmpDest = $dest + ".part"
    try {
        # Get file size for progress bar
        $meta  = Get-S3ObjectMetadata -BucketName $S3Bucket -Key $S3Key -Region "us-east-1" -ErrorAction SilentlyContinue
        $total = if ($meta) { $meta.ContentLength } else { 0 }

        # Progress bar runs in a runspace, polling file size every 300ms
        # Copy-S3Object runs in the main thread so credentials are available
        $tmpDest = $dest + ".part"
        $pbFlag  = [System.Collections.Generic.List[bool]]::new(); $pbFlag.Add($false)
        $pbTotal = [System.Collections.Generic.List[long]]::new(); $pbTotal.Add($total)
        $pbRs    = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $pbRs.Open()
        $pbRs.SessionStateProxy.SetVariable('pbFlag',  $pbFlag)
        $pbRs.SessionStateProxy.SetVariable('pbTotal', $pbTotal)
        $pbRs.SessionStateProxy.SetVariable('tmpDest', $tmpDest)
        $pbPsh = [System.Management.Automation.PowerShell]::Create()
        $pbPsh.Runspace = $pbRs
        $pbPsh.AddScript({
            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
            [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
            $filled_c = [char]0x2588  # full block (more widely supported)
            $empty_c  = [char]0x2591  # light shade
            $width = 30
            while (-not $pbFlag[0]) {
                $cur   = if ([System.IO.File]::Exists($tmpDest)) { (New-Object System.IO.FileInfo($tmpDest)).Length } else { 0 }
                $tot   = $pbTotal[0]
                $pct   = if ($tot -gt 0) { [math]::Min(100,[int]($cur*100/$tot)) } else { 0 }
                $fill  = [math]::Round($width * $pct / 100)
                $bar   = $filled_c.ToString() * $fill + $empty_c.ToString() * ($width - $fill)
                $curMB = [math]::Round($cur / 1MB, 0)
                $totMB = [math]::Round($tot / 1MB, 0)
                [Console]::Write("`r  $pct%  $bar  $curMB / $totMB MB   ")
                Start-Sleep -Milliseconds 300
            }
        }) | Out-Null
        $pbHandle = $pbPsh.BeginInvoke()

        # Download on main thread -- stdout suppressed so progress bar is not interrupted
        $oldOut = [Console]::Out
        [Console]::SetOut([System.IO.TextWriter]::Null)
        try {
            Copy-S3Object -BucketName $S3Bucket -Key $S3Key -LocalFile $tmpDest -Region "us-east-1" -ErrorAction Stop | Out-Null
        } finally {
            [Console]::SetOut($oldOut)
        }

        $pbFlag[0] = $true
        $pbPsh.EndInvoke($pbHandle) | Out-Null
        $pbPsh.Dispose(); $pbRs.Close()

        if (Test-Path $tmpDest) { Move-Item $tmpDest $dest -Force }
        $sizeMB  = [math]::Round((Get-Item $dest).Length / 1MB, 0)
        $fullBar = ([char]0x2588).ToString() * 30
        Write-Host "`r  100%  $fullBar  $sizeMB MB       " -ForegroundColor Green
        Write-Log "Downloaded: $(Split-Path $dest -Leaf) ($sizeMB MB)" -Level "OK"
        return $dest
    } catch {
        if (Test-Path $tmpDest) { Remove-Item $tmpDest -Force -ErrorAction SilentlyContinue }
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
        # Use PassThru without -Wait so the spinner runspace keeps running
        $proc = Start-Process -FilePath $InstallerPath -ArgumentList $argList -PassThru -NoNewWindow
        while (-not $proc.HasExited) { Start-Sleep -Milliseconds 500 }
        Stop-Spinner -ctx $spinCtx -Done "Install complete." -Color $color
        [Console]::Out.Flush()
        Write-Host ""
        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 14) {
            Write-Log "Driver installed successfully (ExitCode: $($proc.ExitCode))" -Level "OK"
            return $true
        }
        Write-Log "Driver installer exited with non-zero code: $($proc.ExitCode)" -Level "WARN"
        return $true
    } catch {
        Stop-Spinner -ctx $spinCtx
        [Console]::Out.Flush()
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
    Write-Host "  Reboot required  ($Reason)" -ForegroundColor Yellow
    Write-Host "  Script will resume automatically at login." -ForegroundColor DarkGray
    Write-Host ""
    if (Prompt-YesNo "Reboot now?") {
        Write-Log "Rebooting now. Resume step: $NextStep" -Level "INFO"
        Start-Sleep -Seconds 5
        Restart-Computer -Force
    } else {
        Write-Log "Reboot deferred. Resume step: $NextStep" -Level "INFO"
        Write-Host "  Reboot when ready. Resume manually with: -Resume" -ForegroundColor DarkGray
    }
}

# -------------------------------------------------------------
#  STATUS + ONLINE CHECK
# -------------------------------------------------------------
function Step-ShowStatus {
    $info = Get-InstalledNvidiaInfo
    if (-not $info.Installed) {
        Write-Host "  No NVIDIA driver detected." -ForegroundColor Red
        Write-Log "No NVIDIA driver detected" -Level "WARN"
        return $info
    }
    $vc = switch ($info.Variant) { "Gaming"{"Magenta"} "GRID"{"Cyan"} default{"Gray"} }
    Write-Host "  $($info.GpuName)" -ForegroundColor White
    Write-Host "  $($info.Variant) $($info.Version)" -ForegroundColor $vc
    Write-Host ""
    Write-Log "GPU: $($info.GpuName) | Driver: $($info.Version) | Variant: $($info.Variant) | Date: $($info.DriverDate)" -Level "INFO"
    return $info
}

function Step-CheckOnline {
    param($info)
    $spinCtx = Start-Spinner -Label "Checking for updates"
    # Fetch current variant first; other is retrieved lazily (both are cached after first call)
    $latestSame  = if ($info.Variant -eq "GRID") { Get-LatestGridVersion }   else { Get-LatestGamingVersion }
    $latestOther = if ($info.Variant -eq "GRID") { Get-LatestGamingVersion } else { Get-LatestGridVersion }
    $latestGaming = if ($info.Variant -eq "Gaming") { $latestSame } else { $latestOther }
    $latestGrid   = if ($info.Variant -eq "GRID")   { $latestSame } else { $latestOther }
    $updateAvailable = $false
    $updateVersion   = ""
    try {
        $latest = $latestSame.Version
        if ([Version]$latest -gt [Version]$info.Version) {
            $updateAvailable = $true; $updateVersion = $latest
        }
    } catch {}
    Stop-Spinner -ctx $spinCtx
    Write-Log "Version check -- Installed: $($info.Version) [$($info.Variant)] | Gaming: $($latestGaming.Version) | GRID: $($latestGrid.Version)" -Level "INFO"
    $s3err = ($latestGaming.Error -and $info.Variant -eq "Gaming") -or ($latestGrid.Error -and $info.Variant -eq "GRID")
    if ($s3err) {
        Write-Host "  [!] Could not reach update server -- version check skipped." -ForegroundColor Yellow
    } elseif ($updateAvailable) {
        Write-Host "  $([char]0x2191) $($info.Variant) $updateVersion available" -ForegroundColor Yellow
    } else {
        Write-Host "  $([char]0x2713) Current $($info.Variant) driver is up to date." -ForegroundColor Green
    }
    Write-Host ""
    return @{ UpdateAvailable=$updateAvailable; LatestGaming=$latestGaming; LatestGrid=$latestGrid }
}

function Step-ActionMenu {
    param($info, $online)
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
    if ($sel -eq 0) { Write-Host "  Cancelled." -ForegroundColor DarkGray; return $null }
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

    # Ensure AWS credentials loaded (may have been skipped on resume path)
    if (-not $script:AwsCredentialsLoaded) {
        $_awsCtx = Start-Spinner -Label "Loading"
        $oldOut = [Console]::Out
        [Console]::SetOut([System.IO.TextWriter]::Null)
        try { Set-AwsCredentials } finally { [Console]::SetOut($oldOut) }
        Stop-Spinner -ctx $_awsCtx
    }

    $state = Load-State
    if (-not $state) { $state = @{} }
    # Merge caller args into state (caller may supply fresher S3 info)
    if ($TargetVariant) { $state.TargetVariant = $TargetVariant }
    if ($Version)       { $state.TargetVersion = $Version }
    if ($S3Bucket)      { $state.S3Bucket      = $S3Bucket }
    if ($S3Key)         { $state.S3Key         = $S3Key }

    # -- STEP 1: PRE-FLIGHT + DOWNLOAD ------------------------
    if ($state.Step -notin @("AFTER_DOWNLOAD","AFTER_UNINSTALL_AND_CLEANUP")) {
        $disk = Get-PSDrive ((Split-Path $DownloadDir -Qualifier).TrimEnd(":")) -ErrorAction SilentlyContinue
        if ($disk -and $disk.Free -lt 2GB) {
            Write-Host "  ERROR: Not enough disk space ($([math]::Round($disk.Free/1GB,1)) GB free, need 2 GB)" -ForegroundColor Red
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
            Write-Host "  Download failed. Current driver untouched." -ForegroundColor Red
            Write-Log "Pre-flight failed: download failed" -Level "ERROR"
            return
        }
        $state.InstallerPath = [string]$installer
        $state.Step = "AFTER_DOWNLOAD"
        Save-State $state
    }

    # -- STEP 2: UNINSTALL + REGISTRY CLEANUP (combined, 1 reboot) --
    if ($state.Step -eq "AFTER_DOWNLOAD") {
        $state.Step = "UNINSTALLING"; Save-State $state
        Invoke-NvidiaUninstall
        Invoke-RegistryCleanup
        $state.Step = "AFTER_UNINSTALL_AND_CLEANUP"; Save-State $state
        Request-Reboot -Reason "Uninstall + registry cleanup completed" -NextStep "AFTER_UNINSTALL_AND_CLEANUP"
        return
    }

    # -- STEP 3: INSTALL ---------------------------------------
    if ($state.Step -eq "AFTER_UNINSTALL_AND_CLEANUP") {
        Write-Host ""

        $installer = [string]$state.InstallerPath
        if (-not $installer -or -not (Test-Path $installer)) {
            Write-Host "  Cached installer missing -- re-downloading..." -ForegroundColor Yellow
            Write-Log "Installer missing from cache, re-downloading" -Level "WARN"
            $installer = Get-DriverPackage -Variant $state.TargetVariant -S3Bucket $state.S3Bucket -S3Key $state.S3Key
        }
        if (-not $installer -or -not (Test-Path $installer)) {
            Write-Host "  No installer available. Cannot continue." -ForegroundColor Red
            Write-Log "Install aborted: no installer available" -Level "ERROR"
            Write-Host ""
            Write-Host "  State preserved. Re-run to retry." -ForegroundColor Yellow
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
            Write-Host "  Installation failed. State preserved -- re-run to retry." -ForegroundColor Red
            Write-Log "Installation failed. State preserved at AFTER_UNINSTALL_AND_CLEANUP." -Level "ERROR"
        }
    }
}

# -------------------------------------------------------------
#  ENTRY POINT
# -------------------------------------------------------------
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8
chcp 65001 | Out-Null  # UTF-8 codepage for correct Braille/block char rendering

foreach ($dir in @($WorkDir,$DownloadDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

Show-Banner

# -- Check for saved state (before loading AWS -- resume may not need S3) ----
$existingState = Load-State
$isResume = $existingState -and $existingState.Step -in @("AFTER_DOWNLOAD","AFTER_UNINSTALL_AND_CLEANUP","UNINSTALLING")

# -- Load AWS credentials (skip on resume -- S3 loaded lazily if needed) ----
if (-not $isResume) {
    $_loadCtx = Start-Spinner -Label "Loading"
    $oldOut = [Console]::Out
    [Console]::SetOut([System.IO.TextWriter]::Null)
    try { Set-AwsCredentials } finally { [Console]::SetOut($oldOut) }
    Stop-Spinner -ctx $_loadCtx
}

if ($isResume) {
    Write-Host ""
    $stepDesc = switch ($existingState.Step) {
        "AFTER_DOWNLOAD"             { "Driver downloaded -- ready to uninstall" }
        "UNINSTALLING"               { "Uninstall in progress -- resuming install" }
        "AFTER_UNINSTALL_AND_CLEANUP"{ "Uninstall done -- ready to install" }
        default                      { $existingState.Step }
    }
    Write-Host ""
    Write-Host "  Resuming: " -NoNewline -ForegroundColor Yellow
    Write-Host $stepDesc -ForegroundColor White
    Write-Log "Resuming from step: $($existingState.Step)" -Level "INFO"
    # Show target info from state (live GPU query unreliable after uninstall)
    $vc = switch ($existingState.TargetVariant) { "Gaming"{"Magenta"} "GRID"{"Cyan"} default{"Gray"} }
    Write-Host "  Installing: " -NoNewline -ForegroundColor DarkGray
    Write-Host "$($existingState.TargetVariant) $($existingState.TargetVersion)" -ForegroundColor $vc
    Write-Host ""
    $rBucket = $existingState.S3Bucket; $rKey = $existingState.S3Key
    if (-not $rBucket -or -not $rKey) {
        Write-Host "  S3 info missing -- re-fetching..." -ForegroundColor Yellow
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
            Write-Host "  Gaming driver is not supported on $($info.GpuName)." -ForegroundColor Red
            Write-Host "  Supported GPUs: T4, A10G, L4, L40S (standard instances only)." -ForegroundColor Yellow
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
    default             { Write-Host "  No action taken." -ForegroundColor DarkGray }
}

