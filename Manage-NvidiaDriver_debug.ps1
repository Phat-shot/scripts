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
    Run as Administrator. No external modules required -- S3 access uses
    native HTTP with AWS Signature V4 (credentials file or EC2 IMDSv2 role).
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
    else        { Write-Host "`r                                      " -NoNewline
                  Write-Host "" }
    [Console]::Out.Flush()
}


# -------------------------------------------------------------
#  RUN WITH SPINNER
#  Runs a ScriptBlock in a Job (separate process, inherits module
#  state), shows spinner on main thread, returns result via temp file.
# -------------------------------------------------------------
function Invoke-WithSpinner {
    param([string]$Label, [scriptblock]$ScriptBlock, [object[]]$ArgumentList = @())
    $tmpFile = [System.IO.Path]::GetTempFileName()
    $job = Start-Job -ScriptBlock {
        param($sb, $args, $out)
        try {
            $result = & ([scriptblock]::Create($sb)) @args
            $result | ConvertTo-Json -Depth 5 | Set-Content $out -Encoding UTF8
        } catch {
            @{ Error = $_.ToString() } | ConvertTo-Json | Set-Content $out -Encoding UTF8
        }
    } -ArgumentList $ScriptBlock.ToString(), $ArgumentList, $tmpFile
    $spinCtx = Start-Spinner -Label $Label
    while ($job.State -eq "Running") { Start-Sleep -Milliseconds 150 }
    Stop-Spinner -ctx $spinCtx
    Receive-Job $job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $job -ErrorAction SilentlyContinue
    $raw = Get-Content $tmpFile -Raw -ErrorAction SilentlyContinue
    Remove-Item $tmpFile -ErrorAction SilentlyContinue
    if ($raw) { return $raw | ConvertFrom-Json } else { return $null }
}

# -------------------------------------------------------------
#  AWS CREDENTIALS  (pure file / IMDSv2 -- no AWSPowerShell)
# -------------------------------------------------------------
$script:AwsCreds = $null   # @{ AccessKey; SecretKey; Token }

function Get-AwsCredentials {
    if ($script:AwsCreds) { return $script:AwsCreds }

    # 1) Static file
    if (Test-Path $AwsCredsFile) {
        try {
            $kvp = @{}
            Get-Content $AwsCredsFile | Where-Object { $_ -match '=' } | ForEach-Object {
                $p = $_ -split '\s*=\s*', 2
                if ($p.Count -eq 2) { $kvp[$p[0].Trim()] = $p[1].Trim() }
            }
            if ($kvp['aws_access_key_id'] -and $kvp['aws_secret_access_key']) {
                $script:AwsCreds = @{
                    AccessKey = $kvp['aws_access_key_id']
                    SecretKey = $kvp['aws_secret_access_key']
                    Token     = $kvp['aws_session_token']
                }
                Write-Log "AWS credentials loaded from file" -Level "INFO"
                return $script:AwsCreds
            }
        } catch { Write-Log "AWS credentials file error: $_" -Level "INFO" }
    }

    # 2) IMDSv2 (EC2 instance role)
    try {
        $tok = Invoke-RestMethod -Method PUT `
            -Uri "http://169.254.169.254/latest/api/token" `
            -Headers @{ "X-aws-ec2-metadata-token-ttl-seconds" = "21600" } `
            -TimeoutSec 2 -ErrorAction Stop
        $role = Invoke-RestMethod `
            -Uri "http://169.254.169.254/latest/meta-data/iam/security-credentials/" `
            -Headers @{ "X-aws-ec2-metadata-token" = $tok } `
            -TimeoutSec 2 -ErrorAction Stop
        $cred = Invoke-RestMethod `
            -Uri "http://169.254.169.254/latest/meta-data/iam/security-credentials/$role" `
            -Headers @{ "X-aws-ec2-metadata-token" = $tok } `
            -TimeoutSec 2 -ErrorAction Stop
        $script:AwsCreds = @{
            AccessKey = $cred.AccessKeyId
            SecretKey = $cred.SecretAccessKey
            Token     = $cred.Token
        }
        Write-Log "AWS credentials loaded from IMDSv2 (role: $role)" -Level "INFO"
        return $script:AwsCreds
    } catch { Write-Log "IMDSv2 not available: $_" -Level "INFO" }

    Write-Log "No AWS credentials found" -Level "WARN"
    return $null
}

# -------------------------------------------------------------
#  AWS SIGNATURE V4  (HMAC-SHA256, no external modules)
# -------------------------------------------------------------
function Get-SigV4Headers {
    param(
        [string]$Method,
        [string]$Uri,
        [hashtable]$QueryParams = @{},
        [string]$Service = "s3",
        [string]$Region  = "us-east-1",
        [string]$Payload = ""
    )
    $creds = Get-AwsCredentials
    if (-not $creds) { throw "No AWS credentials available" }

    $uriObj    = [System.Uri]$Uri
    $host_     = $uriObj.Host
    $now       = [System.DateTime]::UtcNow
    $dateStamp = $now.ToString("yyyyMMdd")
    $amzDate   = $now.ToString("yyyyMMddTHHmmssZ")

    # Canonical query string (sorted)
    $sortedQ = ($QueryParams.GetEnumerator() | Sort-Object Key |
        ForEach-Object { [uri]::EscapeDataString($_.Key) + "=" + [uri]::EscapeDataString($_.Value) }) -join "&"

    # Payload hash
    $sha256  = [System.Security.Cryptography.SHA256]::Create()
    $payHash = ($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Payload)) |
                ForEach-Object { $_.ToString("x2") }) -join ""

    # Headers to sign
    $headers = [ordered]@{
        "host"                 = $host_
        "x-amz-content-sha256" = $payHash
        "x-amz-date"           = $amzDate
    }
    if ($creds.Token) { $headers["x-amz-security-token"] = $creds.Token }

    $signedHeaders   = ($headers.Keys -join ";")
    $canonicalHeaders = ($headers.GetEnumerator() | ForEach-Object { "$($_.Key):$($_.Value)`n" }) -join ""

    $canonicalPath = if ($uriObj.AbsolutePath) { $uriObj.AbsolutePath } else { "/" }
    $canonicalReq  = "$Method`n$canonicalPath`n$sortedQ`n$canonicalHeaders`n$signedHeaders`n$payHash"
    $credScope     = "$dateStamp/$Region/$Service/aws4_request"
    $reqHash       = ($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canonicalReq)) |
                      ForEach-Object { $_.ToString("x2") }) -join ""
    $strToSign     = "AWS4-HMAC-SHA256`n$amzDate`n$credScope`n$reqHash"

    # HMAC helper
    function HmacSha256([byte[]]$key, [string]$data) {
        $h = New-Object System.Security.Cryptography.HMACSHA256
        $h.Key = $key
        return $h.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($data))
    }
    $kDate    = HmacSha256 ([System.Text.Encoding]::UTF8.GetBytes("AWS4$($creds.SecretKey)")) $dateStamp
    $kRegion  = HmacSha256 $kDate    $Region
    $kService = HmacSha256 $kRegion  $Service
    $kSigning = HmacSha256 $kService "aws4_request"
    $sig      = (HmacSha256 $kSigning $strToSign | ForEach-Object { $_.ToString("x2") }) -join ""

    $authHeader = "AWS4-HMAC-SHA256 Credential=$($creds.AccessKey)/$credScope, " +
                  "SignedHeaders=$signedHeaders, Signature=$sig"

    $reqHeaders = @{
        "Authorization"        = $authHeader
        "x-amz-content-sha256" = $payHash
        "x-amz-date"           = $amzDate
        "Host"                 = $host_
    }
    if ($creds.Token) { $reqHeaders["x-amz-security-token"] = $creds.Token }
    return $reqHeaders
}

# Convenience: S3 ListObjectsV2 for a bucket/prefix, returns array of Key strings
function Invoke-S3ListObjects {
    param([string]$Bucket, [string]$Prefix, [string]$Region = "us-east-1")
    $uri  = "https://$Bucket.s3.$Region.amazonaws.com/"
    $qp   = @{ "list-type" = "2"; prefix = $Prefix }
    $hdrs = Get-SigV4Headers -Method "GET" -Uri $uri -QueryParams $qp -Region $Region
    $qs   = ($qp.GetEnumerator() | Sort-Object Key |
             ForEach-Object { [uri]::EscapeDataString($_.Key) + "=" + [uri]::EscapeDataString($_.Value) }) -join "&"
    $resp = Invoke-RestMethod -Method GET -Uri "${uri}?${qs}" -Headers $hdrs -ErrorAction Stop
    return @($resp.ListBucketResult.Contents | ForEach-Object { $_.Key })
}

# Convenience: S3 HEAD (returns ContentLength or 0)
function Invoke-S3Head {
    param([string]$Bucket, [string]$Key, [string]$Region = "us-east-1")
    $uri  = "https://$Bucket.s3.$Region.amazonaws.com/$Key"
    $hdrs = Get-SigV4Headers -Method "HEAD" -Uri $uri -Region $Region
    try {
        $resp = Invoke-WebRequest -Method HEAD -Uri $uri -Headers $hdrs -ErrorAction Stop
        return [long]$resp.Headers["Content-Length"]
    } catch { return 0L }
}

# Convenience: S3 GET with streaming download + progress callback
function Invoke-S3Download {
    param([string]$Bucket, [string]$Key, [string]$OutFile, [string]$Region = "us-east-1")
    $uri  = "https://$Bucket.s3.$Region.amazonaws.com/$Key"
    $hdrs = Get-SigV4Headers -Method "GET" -Uri $uri -Region $Region
    Invoke-WebRequest -Method GET -Uri $uri -Headers $hdrs -OutFile $OutFile -ErrorAction Stop | Out-Null
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
        } catch { Write-Log "Could not load state: $_" -Level "INFO" }
    }
    return $null
}

function Clear-State {
    if (Test-Path $StateFile) { Remove-Item $StateFile -Force }
    Remove-ItemProperty -Path $RunKey -Name $RunName -Force -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "airgpuDriverManagerResume" -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "State and resume task cleared." -Level "INFO"
}

function Invoke-Cleanup {
    # Remove Downloads folder
    try {
        if (Test-Path $DownloadDir) {
            Remove-Item $DownloadDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Downloads folder removed." -Level "INFO"
        }
    } catch { Write-Log "Download cleanup: $_" -Level "INFO" }
    # Schedule script self-deletion after exit (cmd /c ping delay trick)
    $script = $MyInvocation.ScriptName
    if ($script -and (Test-Path $script)) {
        $del = "ping -n 3 127.0.0.1 > nul & del /f /q `"$script`""
        Start-Process "cmd.exe" -ArgumentList "/c $del" -WindowStyle Hidden
        Write-Log "Script queued for deletion: $script" -Level "INFO"
    }
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
        $keys = Invoke-S3ListObjects -Bucket $Bucket -Prefix $Prefix
        $exeKey = $keys | Where-Object { $_ -like "*.exe" } | Select-Object -First 1
        if ($exeKey -and (Split-Path $exeKey -Leaf) -match '(\d+\.\d+)') {
            return @{ Version=$Matches[1]; S3Key=$exeKey; S3Bucket=$Bucket; Error=$false }
        }
        Write-Log "S3 lookup: no .exe found in $Bucket/$Prefix" -Level "INFO"
        return @{ Version="Unknown"; S3Key=""; S3Bucket=""; Error=$false }
    } catch {
        Write-Log "S3 lookup failed ($Bucket): $_" -Level "INFO"
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
    if ($GpuName -match '(?i)\bL4\b' -and $GpuName -notmatch '(?i)\bL4[-a-zA-Z0-9]') { return $true }
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
        } catch { Write-Log "Failed to uninstall '$($app.DisplayName)': $_" -Level "INFO" }
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
        } catch { Write-Log "Display driver uninstall failed: $_" -Level "INFO" }
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

    Stop-Spinner -ctx $spinCtx -Done "Uninstall complete." -Color "DarkCyan"
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
        Write-Host "  Cannot proceed: S3 source not available and no cached installer." -ForegroundColor Red
        Write-Host "  Ensure AWS credentials or IAM role are configured and S3 is reachable." -ForegroundColor Yellow
        Write-Log "Install aborted: no S3 source (no credentials/IAM role)" -Level "ERROR"
        return
    }

    $dest = "$DownloadDir\$(Split-Path $S3Key -Leaf)"
    if (Test-Path $dest) {
        Write-Host "  Using cached installer: $(Split-Path $dest -Leaf)" -ForegroundColor White
        return $dest
    }

    Write-Host "  Downloading $(Split-Path $S3Key -Leaf)" -ForegroundColor DarkCyan
    $tmpDest = $dest + ".part"
    try {
        # HEAD request for file size (pure HTTP, no AWSPowerShell)
        $total = Invoke-S3Head -Bucket $S3Bucket -Key $S3Key
        if (-not $total) { $total = 0 }

        # Progress bar runs in a runspace, polling file size every 300ms
        # Invoke-S3Download runs in the main thread
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
                [Console]::Write("`r  $pct%  $bar  $curMB / $totMB MB        ")
                Start-Sleep -Milliseconds 300
            }
        }) | Out-Null
        $pbHandle = $pbPsh.BeginInvoke()

        # Download on main thread via signed HTTP GET (no AWSPowerShell)
        $oldOut = [Console]::Out
        [Console]::SetOut([System.IO.TextWriter]::Null)
        try {
            Invoke-S3Download -Bucket $S3Bucket -Key $S3Key -OutFile $tmpDest
        } finally {
            [Console]::SetOut($oldOut)
        }

        $pbFlag[0] = $true
        $pbPsh.EndInvoke($pbHandle) | Out-Null
        $pbPsh.Dispose(); $pbRs.Close()

        if (Test-Path $tmpDest) { Move-Item $tmpDest $dest -Force }
        $sizeMB  = [math]::Round((Get-Item $dest).Length / 1MB, 0)
        $fullBar = ([char]0x2588).ToString() * 30
        $pad = " " * 20
        Write-Host "`r  100%  $fullBar  $sizeMB MB  $pad" -ForegroundColor DarkCyan
        Write-Host ""
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
function Install-NvidiaControlPanel {
    # Install NVIDIA Control Panel from the Microsoft Store (msix bundle)
    # Product ID: 9NF8H0H7WMLT
    Write-Log "Installing NVIDIA Control Panel from Store" -Level "INFO"
    $spinCtx = Start-Spinner -Label "Installing NVIDIA Control Panel"
    $ok = $false
    try {
        # Preferred: winget (available on Win11, silent)
        $wgCmd = Get-Command winget -ErrorAction SilentlyContinue
        if ($wgCmd) {
            # Run winget fully hidden via cmd.exe to suppress all console output
            $wgArgs = "install --id 9NF8H0H7WMLT --source msstore" +
                      " --accept-package-agreements --accept-source-agreements" +
                      " --silent --disable-interactivity"
            $wgLog = "$env:TEMP\winget_cp_$([System.IO.Path]::GetRandomFileName()).log"
            $proc = Start-Process -FilePath "cmd.exe" `
                -ArgumentList @("/c", "winget $wgArgs > `"$wgLog`" 2>&1") `
                -PassThru -WindowStyle Hidden -Wait
            $ok = ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq -1978335189)
            Write-Log "winget NVIDIA Control Panel: ExitCode $($proc.ExitCode)" -Level "INFO"
            Remove-Item $wgLog -ErrorAction SilentlyContinue
        }
        # Fallback: direct MSIX download from Store CDN (only if winget not available)
        if (-not $ok -and -not $wgCmd) {
            $uri = "https://store.rg-adguard.net/api/GetFiles?type=PackageFamilyName&url=NVIDIACorp.NVIDIAControlPanel_56jybvy8sckqj&ring=Retail&lang=en-US"
            $links = (Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 30 -ErrorAction SilentlyContinue).Links |
                Where-Object { $_.href -match "\.msixbundle|\.appxbundle" -and $_.href -notmatch "blockmap" } |
                Select-Object -First 1
            if ($links) {
                $msix = Join-Path $env:TEMP "NvidiaCP.msixbundle"
                Invoke-WebRequest -Uri $links.href -OutFile $msix -UseBasicParsing -TimeoutSec 120 -ErrorAction SilentlyContinue
                if (Test-Path $msix) {
                    Add-AppxPackage -Path $msix -ErrorAction SilentlyContinue
                    $ok = $?
                    Remove-Item $msix -ErrorAction SilentlyContinue
                    Write-Log "MSIX bundle install result: $ok" -Level "INFO"
                }
            }
        }
    } catch {
        Write-Log "Control Panel install warning: $_" -Level "INFO"
    }
    Stop-Spinner -ctx $spinCtx -Done $(if($ok){"Control Panel installed."}else{"Control Panel install skipped."}) `
        -Color $(if($ok){"DarkCyan"}else{"DarkGray"})
    [Console]::Out.Flush()
    # Return via script-scoped var to avoid bool leaking to pipeline
    $script:_cpResult = $ok
}

function Install-NvidiaDriver {
    param([string]$InstallerPath, [string]$Variant)
    if (-not $InstallerPath -or -not (Test-Path $InstallerPath)) {
        Write-Log "Installer not found: $InstallerPath" -Level "ERROR"
        return $false
    }
    Write-Log "Silent install started: $(Split-Path $InstallerPath -Leaf) [$Variant]" -Level "INFO"
    $argList = @("-s","-noreboot","-clean")
    if ($Variant -eq "GRID") { $argList += "-noeula" }
    $color = "DarkCyan"
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
        Write-Log "Driver installer exited with non-zero code: $($proc.ExitCode) (treated as success)" -Level "INFO"
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
    } catch { Write-Log "Gaming registry key failed: $_" -Level "INFO" }
    try {
        Invoke-WebRequest -Uri "https://nvidia-gaming.s3.amazonaws.com/GridSwCert-Archive/GridSwCertWindows_2024_02_22.cert" `
            -OutFile "$env:PUBLIC\Documents\GridSwCert.txt" -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        Write-Log "Gaming cert downloaded" -Level "OK"
    } catch {
        Write-Log "Gaming cert download failed (licensing may not work): $_" -Level "INFO"
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
    $spinCtx = Start-Spinner -Label "Detecting GPU"
    $info    = Get-InstalledNvidiaInfo
    Stop-Spinner -ctx $spinCtx
    if (-not $info.Installed) {
        Write-Host "  No NVIDIA driver detected." -ForegroundColor Red
        Write-Log "No NVIDIA driver detected" -Level "WARN"
        return $info
    }
    $vc = "DarkCyan"
    Write-Host "  $($info.GpuName)" -ForegroundColor DarkCyan
    Write-Host "  $($info.Variant) $($info.Version)" -ForegroundColor $vc
    Write-Host ""
    Write-Log "GPU: $($info.GpuName) | Driver: $($info.Version) | Variant: $($info.Variant) | Date: $($info.DriverDate)" -Level "INFO"
    return $info
}

function Step-CheckOnline {
    param($info)
    # S3 versions already fetched during load -- just read cache
    $latestGaming = $script:S3CacheGaming
    $latestGrid   = $script:S3CacheGrid
    $updateAvailable = $false; $updateVersion = ""
    try {
        $latest = if ($info.Variant -eq "GRID") { $latestGrid.Version } else { $latestGaming.Version }
        if ($latest -and $latest -ne "Unknown" -and [Version]$latest -gt [Version]$info.Version) {
            $updateAvailable = $true; $updateVersion = $latest
        }
    } catch {}
    Write-Log "Version check -- Installed: $($info.Version) [$($info.Variant)] | Gaming: $($latestGaming.Version) | GRID: $($latestGrid.Version)" -Level "INFO"
    $s3err = ($latestGaming.Error -and $info.Variant -eq "Gaming") -or ($latestGrid.Error -and $info.Variant -eq "GRID")
    if ($s3err) {
        Write-Host "  [!] Could not reach update server -- version check skipped." -ForegroundColor Yellow
    } elseif ($updateAvailable) {
        Write-Host "  $([char]0x2191) $($info.Variant) $updateVersion available" -ForegroundColor Yellow
    } else {
        Write-Host "  $([char]0x2713) Current $($info.Variant) driver is up to date." -ForegroundColor White
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
            if ($online.LatestGaming.Error) {
                $opts += "Switch to Gaming / GeForce driver  [S3 unavailable -- check credentials]"
            } else {
                $opts += "Switch to Gaming / GeForce driver"
            }
        } else {
            Write-Host "  [i] $($info.GpuName) supports GRID only -- Gaming driver not available for this GPU." -ForegroundColor DarkCyan
        }
    }
    if (-not $online.UpdateAvailable) { $opts += "Reinstall current driver  ($($info.Version))" }
    $sel = Prompt-Menu "What would you like to do?" $opts
    if ($sel -eq 0) {
        Write-Host "  Cancelled." -ForegroundColor White
        Invoke-Cleanup
        return $null
    }
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
    # AWS only needed if we have to download (Step 1)
    # On resume after reboot the installer is already cached -- skip AWS entirely
    $needsDownload = $state.Step -notin @("AFTER_DOWNLOAD","AFTER_UNINSTALL_AND_CLEANUP")
    $installerCached = $state.InstallerPath -and (Test-Path ([string]$state.InstallerPath))
    if ($needsDownload -and -not $installerCached -and -not $script:AwsCredentialsLoaded) {
        $jobGaming = Start-Job -ScriptBlock $s3JobSb -ArgumentList "nvidia-gaming",              "windows/latest/", $AwsCredsFile
        $jobGrid   = Start-Job -ScriptBlock $s3JobSb -ArgumentList "ec2-windows-nvidia-drivers", "latest/",         $AwsCredsFile
        $_awsCtx   = Start-Spinner -Label "Loading"
        while ($jobGaming.State -eq "Running" -or $jobGrid.State -eq "Running") { Start-Sleep -Milliseconds 150 }
        Stop-Spinner -ctx $_awsCtx
        $script:S3CacheGaming = Receive-Job $jobGaming -ErrorAction SilentlyContinue
        $script:S3CacheGrid   = Receive-Job $jobGrid   -ErrorAction SilentlyContinue
        Remove-Job $jobGaming, $jobGrid -ErrorAction SilentlyContinue
        if (-not $script:S3CacheGaming) { $script:S3CacheGaming = @{ Version="Unknown"; S3Key=""; S3Bucket="nvidia-gaming"; Error=$true } }
        if (-not $script:S3CacheGrid)   { $script:S3CacheGrid   = @{ Version="Unknown"; S3Key=""; S3Bucket="ec2-windows-nvidia-drivers"; Error=$true } }
        Set-AwsCredentials
    }
    if (-not $state) { $state = @{} }
    # Merge caller args into state (caller may supply fresher S3 info)
    if ($TargetVariant) { $state.TargetVariant = $TargetVariant }
    if ($Version)       { $state.TargetVersion = $Version }
    if ($S3Bucket)      { $state.S3Bucket      = $S3Bucket }
    if ($S3Key)         { $state.S3Key         = $S3Key }

    # -- STEP 1: PRE-FLIGHT + DOWNLOAD ------------------------
    if ($state.Step -notin @("AFTER_DOWNLOAD","AFTER_UNINSTALL_AND_CLEANUP")) {
        Write-Host ""
        Write-Host "  Checking prerequisites..." -ForegroundColor DarkCyan
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
            Install-NvidiaControlPanel | Out-Null
            Clear-State
            # Cleanup: remove downloads + self-delete script
            Invoke-Cleanup
            # Remove script (EXE will re-download fresh next run)
            $selfScript = $MyInvocation.ScriptName
            Write-Host ""
            Write-Host "  Done. Driver installed successfully." -ForegroundColor White
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

# -- Load AWS + prefetch S3 versions in parallel (3 background jobs) --------
if (-not $isResume) {
    $s3JobSb = {
        param($bucket, $prefix, $credsFile)
        # ---- inline Sig V4 helpers (jobs run in isolated runspaces) ----
        function _GetCreds($f) {
            if (Test-Path $f) {
                $kvp = @{}
                Get-Content $f | Where-Object { $_ -match '=' } | ForEach-Object {
                    $p = $_ -split '\s*=\s*', 2; if ($p.Count -eq 2) { $kvp[$p[0].Trim()] = $p[1].Trim() }
                }
                if ($kvp['aws_access_key_id'] -and $kvp['aws_secret_access_key']) {
                    return @{ AccessKey=$kvp['aws_access_key_id']; SecretKey=$kvp['aws_secret_access_key']; Token=$kvp['aws_session_token'] }
                }
            }
            # IMDSv2 fallback
            try {
                $tok  = Invoke-RestMethod -Method PUT -Uri "http://169.254.169.254/latest/api/token" `
                            -Headers @{"X-aws-ec2-metadata-token-ttl-seconds"="21600"} -TimeoutSec 2 -EA Stop
                $role = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/iam/security-credentials/" `
                            -Headers @{"X-aws-ec2-metadata-token"=$tok} -TimeoutSec 2 -EA Stop
                $c    = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/iam/security-credentials/$role" `
                            -Headers @{"X-aws-ec2-metadata-token"=$tok} -TimeoutSec 2 -EA Stop
                return @{ AccessKey=$c.AccessKeyId; SecretKey=$c.SecretAccessKey; Token=$c.Token }
            } catch {}
            return $null
        }
        function _SigHdrs($method,$uri,$qp,$creds) {
            $uObj=$([System.Uri]$uri); $now=[DateTime]::UtcNow
            $ds=$now.ToString("yyyyMMdd"); $amz=$now.ToString("yyyyMMddTHHmmssZ")
            $qs=($qp.GetEnumerator()|Sort-Object Key|ForEach-Object{[uri]::EscapeDataString($_.Key)+"="+[uri]::EscapeDataString($_.Value)})-join"&"
            $sha=[System.Security.Cryptography.SHA256]::Create()
            $pH=($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(""))|ForEach-Object{$_.ToString("x2")})-join""
            $hdrs=[ordered]@{"host"=$uObj.Host;"x-amz-content-sha256"=$pH;"x-amz-date"=$amz}
            if($creds.Token){$hdrs["x-amz-security-token"]=$creds.Token}
            $sh=($hdrs.Keys-join";")
            $ch=($hdrs.GetEnumerator()|ForEach-Object{"$($_.Key):$($_.Value)`n"})-join""
            $cr="$method`n$($uObj.AbsolutePath)`n$qs`n$ch`n$sh`n$pH"
            $scope="$ds/us-east-1/s3/aws4_request"
            $rh=($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($cr))|ForEach-Object{$_.ToString("x2")})-join""
            $sts="AWS4-HMAC-SHA256`n$amz`n$scope`n$rh"
            function _H([byte[]]$k,[string]$d){$h=New-Object Security.Cryptography.HMACSHA256;$h.Key=$k;$h.ComputeHash([Text.Encoding]::UTF8.GetBytes($d))}
            $kD=_H ([Text.Encoding]::UTF8.GetBytes("AWS4$($creds.SecretKey)")) $ds
            $kR=_H $kD "us-east-1"; $kS=_H $kR "s3"; $kSig=_H $kS "aws4_request"
            $sig=(_H $kSig $sts|ForEach-Object{$_.ToString("x2")})-join""
            $auth="AWS4-HMAC-SHA256 Credential=$($creds.AccessKey)/$scope, SignedHeaders=$sh, Signature=$sig"
            $out=@{"Authorization"=$auth;"x-amz-content-sha256"=$pH;"x-amz-date"=$amz;"Host"=$uObj.Host}
            if($creds.Token){$out["x-amz-security-token"]=$creds.Token}
            return $out
        }
        try {
            $creds = _GetCreds $credsFile
            if (-not $creds) { return @{ Version="Unknown"; S3Key=""; S3Bucket=$bucket; Error=$true } }
            $uri  = "https://$bucket.s3.us-east-1.amazonaws.com/"
            $qp   = @{"list-type"="2"; prefix=$prefix}
            $hdrs = _SigHdrs "GET" $uri $qp $creds
            $qs   = ($qp.GetEnumerator()|Sort-Object Key|ForEach-Object{[uri]::EscapeDataString($_.Key)+"="+[uri]::EscapeDataString($_.Value)})-join"&"
            $resp = Invoke-RestMethod -Method GET -Uri "${uri}?${qs}" -Headers $hdrs -ErrorAction Stop
            $exeKey = @($resp.ListBucketResult.Contents | ForEach-Object { $_.Key }) |
                        Where-Object { $_ -like "*.exe" } | Select-Object -First 1
            if ($exeKey -and (Split-Path $exeKey -Leaf) -match "(\d+\.\d+)") {
                return @{ Version=$Matches[1]; S3Key=$exeKey; S3Bucket=$bucket; Error=$false }
            }
            return @{ Version="Unknown"; S3Key=""; S3Bucket=$bucket; Error=$false }
        } catch {
            return @{ Version="Unknown"; S3Key=""; S3Bucket=$bucket; Error=$true }
        }
    }
    $jobGaming = Start-Job -ScriptBlock $s3JobSb -ArgumentList "nvidia-gaming",              "windows/latest/", $AwsCredsFile
    $jobGrid   = Start-Job -ScriptBlock $s3JobSb -ArgumentList "ec2-windows-nvidia-drivers", "latest/",         $AwsCredsFile
    $_loadCtx  = Start-Spinner -Label "Loading"
    while ($jobGaming.State -eq "Running" -or $jobGrid.State -eq "Running") { Start-Sleep -Milliseconds 150 }
    Stop-Spinner -ctx $_loadCtx
    $script:S3CacheGaming = Receive-Job $jobGaming -ErrorAction SilentlyContinue
    $script:S3CacheGrid   = Receive-Job $jobGrid   -ErrorAction SilentlyContinue
    Remove-Job $jobGaming, $jobGrid -ErrorAction SilentlyContinue
    if (-not $script:S3CacheGaming) { $script:S3CacheGaming = @{ Version="Unknown"; S3Key=""; S3Bucket="nvidia-gaming"; Error=$true } }
    if (-not $script:S3CacheGrid)   { $script:S3CacheGrid   = @{ Version="Unknown"; S3Key=""; S3Bucket="ec2-windows-nvidia-drivers"; Error=$true } }
    # Warn early if S3 is unreachable -- likely missing credentials or IAM role
    if ($script:S3CacheGaming.Error -and $script:S3CacheGrid.Error) {
        Write-Host ""
        Write-Host "  [!] Cannot reach AWS S3 -- driver downloads will not be available." -ForegroundColor Yellow
        Write-Host "      Cause: missing credentials or IAM role lacks S3 read permission." -ForegroundColor DarkGray
        Write-Host "      File:  C:\Users\user\.aws\credentials" -ForegroundColor DarkGray
        Write-Host ""
        Write-Log "S3 unreachable: both buckets failed -- no credentials or IAM role configured" -Level "INFO"
    }
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
    Write-Host "  Resuming: " -NoNewline -ForegroundColor DarkCyan
    Write-Host $stepDesc -ForegroundColor White
    Write-Log "Resuming from step: $($existingState.Step)" -Level "INFO"
    # Show target info from state (live GPU query unreliable after uninstall)
    $vc = "DarkCyan"
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
        } elseif ($action -like "*check credentials*") {
            Write-Host "  Cannot proceed: S3 is unreachable." -ForegroundColor Red
            Write-Host "  Configure AWS credentials or IAM role with S3 read access." -ForegroundColor Yellow
            Write-Host "  File: C:\Users\user\.aws\credentials" -ForegroundColor DarkGray
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
    default             { Write-Host "  No action taken." -ForegroundColor White }
}

