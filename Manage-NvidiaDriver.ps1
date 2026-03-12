#Requires -RunAsAdministrator
param([switch]$DebugS3)
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
    Run as Administrator. Working dir: C:\Program Files\airgpu\Driver Manager\
    Log file: C:\Program Files\airgpu\Driver Manager\driver_manager.log
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
$script:S3CacheGaming = $null
$script:S3CacheGrid   = $null
$script:AwsCreds      = $null

# -------------------------------------------------------------
#  LOGGING
# -------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    if ($Level -eq "WARN")  { Write-Host "  [!] $Message" -ForegroundColor Yellow }
    if ($Level -eq "ERROR") { Write-Host "  `[x`] $Message" -ForegroundColor Red }
}

# -------------------------------------------------------------
#  SPINNER
# -------------------------------------------------------------
function Start-Spinner {
    param([string]$Label = "Loading")
    $ctx = @{ Stop = $false; Thread = $null }
    $sb  = {
        param($lbl, $ctxRef)
        $frames = [char]0x28F7,[char]0x28EF,[char]0x28DF,[char]0x287F,[char]0x28BF,[char]0x28FB,[char]0x28FD,[char]0x28FE
        $i = 0
        while (-not $ctxRef.Stop) {
            [Console]::Write("`r  " + $frames[$i % $frames.Count] + " $lbl...")
            $i++
            Start-Sleep -Milliseconds 80
        }
        [Console]::Write("`r" + (" " * ($lbl.Length + 10)) + "`r")
    }
    $rs  = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $psh = [System.Management.Automation.PowerShell]::Create()
    $psh.Runspace = $rs
    $psh.AddScript($sb).AddArgument($Label).AddArgument($ctx) | Out-Null
    $ctx.Thread = $psh.BeginInvoke()
    $ctx.Psh    = $psh
    $ctx.Rs     = $rs
    return $ctx
}

function Stop-Spinner {
    param($ctx, [string]$Done = "", [string]$Color = "DarkCyan")
    $ctx.Stop = $true
    Start-Sleep -Milliseconds 120
    try { $ctx.Psh.EndInvoke($ctx.Thread) } catch {}
    $ctx.Psh.Dispose()
    $ctx.Rs.Close()
    if ($Done) { Write-Host "  $Done" -ForegroundColor $Color }
}

# -------------------------------------------------------------
#  AWS CREDENTIALS (no AWSPowerShell module required)
# -------------------------------------------------------------
function Get-AwsCreds {
    # 1. Try credentials file
    if (Test-Path $AwsCredsFile) {
        try {
            $kvp = @{}
            Get-Content $AwsCredsFile | Where-Object { $_ -match '=' } | ForEach-Object {
                $p = $_ -split '\s*=\s*', 2
                if ($p.Count -eq 2) { $kvp[$p[0].Trim()] = $p[1].Trim() }
            }
            $k = $kvp['aws_access_key_id']; $s = $kvp['aws_secret_access_key']
            if ($k -and $s) {
                Write-Log "AWS credentials loaded from file" -Level "INFO"
                return @{ Key=$k; Secret=$s; Token='' }
            }
        } catch {}
    }
    # 2. Try IMDSv2 instance role
    try {
        $token = (Invoke-WebRequest -Uri 'http://169.254.169.254/latest/api/token' `
            -Method PUT -Headers @{'X-aws-ec2-metadata-token-ttl-seconds'='21600'} `
            -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop).Content
        $role = (Invoke-WebRequest -Uri 'http://169.254.169.254/latest/meta-data/iam/security-credentials/' `
            -Headers @{'X-aws-ec2-metadata-token'=$token} `
            -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop).Content.Trim()
        if ($role) {
            $j = (Invoke-WebRequest -Uri "http://169.254.169.254/latest/meta-data/iam/security-credentials/$role" `
                -Headers @{'X-aws-ec2-metadata-token'=$token} `
                -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop).Content | ConvertFrom-Json
            Write-Log "AWS credentials loaded from IAM role: $role" -Level "INFO"
            return @{ Key=$j.AccessKeyId; Secret=$j.SecretAccessKey; Token=$j.Token }
        }
    } catch {
        Write-Log "[TIMING] IMDSv2 failed/timeout" -Level "INFO"
    }
    Write-Log "No AWS credentials found" -Level "INFO"
    return $null
}

# -------------------------------------------------------------
#  AWS SIG V4 HELPERS
# -------------------------------------------------------------
function Get-SHA256Hash {
    param([string]$s)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    [BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))).Replace('-','').ToLower()
}

function Get-HmacSHA256 {
    param([byte[]]$key, [string]$data)
    $h = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList @(,$key)
    return $h.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($data))
}

function Get-SigV4Headers {
    param($Method, $Bucket, $Path, $Query, $Creds)
    $region  = 'us-east-1'
    $now     = [DateTime]::UtcNow
    $amzDate = $now.ToString('yyyyMMddTHHmmssZ')
    $date    = $now.ToString('yyyyMMdd')
    $bodyHash = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
    $host_hdr = "$Bucket.s3.amazonaws.com"
    $canonHeaders = "host:$host_hdr`nx-amz-content-sha256:$bodyHash`nx-amz-date:$amzDate`n"
    $signedHeaders = 'host;x-amz-content-sha256;x-amz-date'
    if ($Creds.Token) {
        $canonHeaders  += "x-amz-security-token:$($Creds.Token)`n"
        $signedHeaders  += ';x-amz-security-token'
    }
    $canonReq = "$Method`n$Path`n$($Query.TrimStart('?'))`n$canonHeaders`n$signedHeaders`n$bodyHash"
    $scope    = "$date/$region/s3/aws4_request"
    $sts      = "AWS4-HMAC-SHA256`n$amzDate`n$scope`n$(Get-SHA256Hash $canonReq)"
    $sigKey   = Get-HmacSHA256 (Get-HmacSHA256 (Get-HmacSHA256 (Get-HmacSHA256 `
                    ([System.Text.Encoding]::UTF8.GetBytes("AWS4$($Creds.Secret)")) $date) $region) 's3') 'aws4_request'
    $sig      = [BitConverter]::ToString((New-Object System.Security.Cryptography.HMACSHA256 `
                    -ArgumentList @(,$sigKey)).ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sts))).Replace('-','').ToLower()
    $h = @{
        'x-amz-date'            = $amzDate
        'x-amz-content-sha256'  = $bodyHash
        'Authorization'         = "AWS4-HMAC-SHA256 Credential=$($Creds.Key)/$scope,SignedHeaders=$signedHeaders,Signature=$sig"
    }
    if ($Creds.Token) { $h['x-amz-security-token'] = $Creds.Token }
    return $h
}

# -------------------------------------------------------------
#  S3 QUERIES  (pure HTTP, no AWSPowerShell)
# -------------------------------------------------------------
function Get-S3DriverInfo {
    param([string]$Bucket, [string]$Prefix, $Creds)
    try {
        $amp = [char]38
        $query   = "list-type=2" + $amp + "prefix=$([Uri]::EscapeDataString($Prefix))" + $amp + "max-keys=20"
        $url     = "https://$Bucket.s3.amazonaws.com/?$query"
        $headers = @{}
        if ($Creds) {
            $headers = Get-SigV4Headers -Method 'GET' -Bucket $Bucket -Path '/' -Query "?$query" -Creds $Creds
        }
        $resp = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        [xml]$xml = $resp.Content
        $key = $xml.ListBucketResult.Contents | Where-Object { $_.Key -like '*.exe' } | Select-Object -ExpandProperty Key -First 1
        if ($key -and ($key -match '(\d+\.\d+)')) {
            return @{ Version=$Matches[1]; S3Key=$key; S3Bucket=$Bucket; Error=$false }
        }
        return @{ Version='Unknown'; S3Key=''; S3Bucket=$Bucket; Error=$false }
    } catch {
        return @{ Version='Unknown'; S3Key=''; S3Bucket=$Bucket; Error=$true; ErrorMsg=$_.ToString() }
    }
}

function Get-LatestGamingVersion {
    if (-not $script:S3CacheGaming) {
        $script:S3CacheGaming = Get-S3DriverInfo -Bucket 'nvidia-gaming' -Prefix 'windows/latest/' -Creds $script:AwsCreds
    }
    return $script:S3CacheGaming
}

function Get-LatestGridVersion {
    if (-not $script:S3CacheGrid) {
        $script:S3CacheGrid = Get-S3DriverInfo -Bucket 'ec2-windows-nvidia-drivers' -Prefix 'latest/' -Creds $script:AwsCreds
    }
    return $script:S3CacheGrid
}

function Test-GamingDriverSupported {
    param([string]$GpuName)
    # L4 variants (L4-3Q, L4f, L4s etc.) are GRID-only
    if ($GpuName -match 'L4[-a-zA-Z0-9]') { return $false }
    return $true
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
            $ht   = @{}
            $json.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
            return $ht
        } catch {}
    }
    return $null
}

function Clear-State {
    if (Test-Path $StateFile) { Remove-Item $StateFile -Force -ErrorAction SilentlyContinue }
    # Remove resume registry key
    try { Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue } catch {}
}

# -------------------------------------------------------------
#  CLEANUP
# -------------------------------------------------------------
function Invoke-Cleanup {
    Clear-Downloads
    Clear-State
    # Self-delete script after exit (delayed via cmd ping trick)
    if ($ScriptPath -and (Test-Path $ScriptPath)) {
        Register-ScriptDeletion $ScriptPath
    }
}

function Clear-Downloads {
    if (Test-Path $DownloadDir) {
        Remove-Item $DownloadDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Downloads folder removed." -Level "INFO"
    }
}

function Register-ScriptDeletion {
    param([string]$Path)
    $escaped = $Path.Replace('"', '\"')
    Start-Process -FilePath "cmd.exe" `
        -ArgumentList ('/c', ("ping -n 3 127.0.0.1 > nul " + [char]38 + " del /f /q `"" + $escaped + "`"")) `
        -WindowStyle Hidden -ErrorAction SilentlyContinue
    Write-Log "Script queued for deletion: $Path" -Level "INFO"
}

function Register-ResumeOnBoot {
    param([string]$Exe)
    $cmd = "`"$Exe`""
    Set-ItemProperty -Path $RunKey -Name $RunName -Value $cmd -ErrorAction SilentlyContinue
    Write-Log "Resume on boot registered: $cmd" -Level "INFO"
}

# -------------------------------------------------------------
#  BANNER
# -------------------------------------------------------------
function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  airgpu Driver Manager" -ForegroundColor DarkCyan
    Write-Host "  ─────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
}

# -------------------------------------------------------------
#  PROMPTS
# -------------------------------------------------------------
function Prompt-YesNo {
    param([string]$Question)
    Write-Host "  $Question [Y/N] " -ForegroundColor Yellow -NoNewline
    $k = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Write-Host ""
    return ($k.Character -eq 'y' -or $k.Character -eq 'Y')
}

function Prompt-Menu {
    param([string]$Title, [object[]]$Options)
    if (-not $Options) { $Options = @() }
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor Yellow
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $label = if ($Options[$i]) { [string]$Options[$i] } else { '' }
        Write-Host "    [$($i+1)] $label"
    }
    Write-Host "    [0] Cancel / Exit"
    Write-Host ""
    do {
        Write-Host "  Selection: " -ForegroundColor Yellow -NoNewline
        $sel = Read-Host
        [int]$num = -1
        [int]::TryParse($sel, [ref]$num) | Out-Null
    } while ($num -lt 0 -or $num -gt $Options.Count)
    return $num
}

# -------------------------------------------------------------
#  GPU DETECTION
# -------------------------------------------------------------
function Get-InstalledNvidiaInfo {
    $result = @{ Installed=$false; Version=''; Variant=''; GpuName=''; DriverDate='' }
    try {
        $gpu = Get-WmiObject Win32_VideoController -ErrorAction Stop |
               Where-Object { $_.Name -match 'NVIDIA' } |
               Select-Object -First 1
        if (-not $gpu) { return $result }
        $result.GpuName = $gpu.Name
        # Detect version from registry
        $regPaths = @(
            'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NVTweak',
            'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E968-E325-11CE-BFC1-08002BE10318}\0000'
        )
        $ver = ''
        foreach ($rp in $regPaths) {
            try {
                $v = (Get-ItemProperty $rp -ErrorAction Stop).DriverVersion
                if ($v -match '(\d+\.\d+)') { $ver = $Matches[1]; break }
            } catch {}
        }
        if (-not $ver -and $gpu.DriverVersion) {
            # WMI format: 31.0.15.x -> take last two groups -> x/100
            if ($gpu.DriverVersion -match '(\d+)\.(\d+)$' -and $Matches -and $Matches.Count -ge 3) {
                $ver = "$($Matches[1]).$($Matches[2])"
            }
        }
        $result.Version = $ver

        # Detect variant: check for vGPU/GRID service or license
        $isGrid = $false
        $gridSvc = Get-Service -Name 'NvContainerLocalSystem','nvlddmkm' -ErrorAction SilentlyContinue |
                   Where-Object { $_.DisplayName -match 'Grid|vGPU|Enterprise' }
        if ($gridSvc) { $isGrid = $true }
        # Also check GPU name
        if ($gpu.Name -match 'Tesla|Quadro|RTX.*A\d|A\d+\s' -and $gpu.Name -notmatch 'GeForce') { $isGrid = $true }
        $result.Variant = if ($isGrid) { 'GRID' } else { 'Gaming' }

        # Driver date from registry
        try {
            $dd = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E968-E325-11CE-BFC1-08002BE10318}\0000' `
                        -ErrorAction Stop).DriverDate
            if ($dd) { $result.DriverDate = $dd }
        } catch {}

        $result.Installed = $true
    } catch {}
    return $result
}

# -------------------------------------------------------------
#  UNINSTALL
# -------------------------------------------------------------
function Invoke-NvidiaUninstall {
    Write-Log "Starting NVIDIA uninstall..." -Level "INFO"
    # 1. Programs & Features uninstall entries
    $apps = @()
    @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') | ForEach-Object {
        $apps += Get-ChildItem $_ -ErrorAction SilentlyContinue |
                 Get-ItemProperty -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -like '*NVIDIA*' -and $_.UninstallString }
    }
    foreach ($app in $apps) {
        Write-Log "Uninstalling: $($app.DisplayName)" -Level "INFO"
        try {
            if ($app.UninstallString -match 'MsiExec') {
                $guidPat = [char]123 + [char]91 + [char]94 + [char]125 + [char]93 + [char]43 + [char]125
                $guidMatch = [regex]::Match($app.UninstallString, $guidPat)
                $guid = $guidMatch.Value
                if ($guid) {
                    $proc = Start-Process msiexec.exe -ArgumentList "/x $guid /quiet /norestart" -PassThru -NoNewWindow
                    if ($proc) { while (-not $proc.HasExited) { Start-Sleep -Milliseconds 500 } }
                }
            } elseif ($app.UninstallString -match '\.exe') {
                $exePat = [char]91 + [char]94 + [char]34 + [char]93 + [char]43 + '\.exe'
                $exeMatch = [regex]::Match($app.UninstallString, $exePat)
                $exe = $exeMatch.Value
                if ($exe -and (Test-Path $exe)) {
                    $proc = Start-Process $exe -ArgumentList '-s -noreboot' -PassThru -NoNewWindow
                    if ($proc) { while (-not $proc.HasExited) { Start-Sleep -Milliseconds 500 } }
                }
            }
        } catch { Write-Log "Failed to uninstall '$($app.DisplayName)': $_" -Level "INFO" }
    }
    # 2. NVI2.EXE / setup.exe
    $setup = Get-ChildItem "$env:ProgramFiles\NVIDIA Corporation\Installer2\InstallerCore" `
                 -Filter 'NVI2.EXE' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $setup) {
        $setup = Get-ChildItem "$env:SystemRoot\System32\DriverStore\FileRepository" `
                     -Filter 'setup.exe' -Recurse -ErrorAction SilentlyContinue |
                     Where-Object { $_.FullName -match 'nv' } | Select-Object -First 1
    }
    if ($setup) {
        Write-Log "Running NVI2/setup uninstall: $($setup.FullName)" -Level "INFO"
        try {
            $proc = Start-Process $setup.FullName -ArgumentList '-passive -noreboot -clean' -PassThru -NoNewWindow
            if ($proc) { $proc.WaitForExit(300000) }
        } catch { Write-Log "NVI2 uninstall error: $_" -Level "INFO" }
    }
    Write-Log "NVIDIA uninstall complete." -Level "INFO"
}

function Invoke-RegistryCleanup {
    Write-Log "Running registry cleanup..." -Level "INFO"
    $keys = @(
        'HKLM:\SOFTWARE\NVIDIA Corporation',
        'HKLM:\SOFTWARE\WOW6432Node\NVIDIA Corporation',
        'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm',
        'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkmSvc'
    )
    foreach ($key in $keys) {
        if (Test-Path $key) {
            try { Remove-Item $key -Recurse -Force -ErrorAction Stop; Write-Log "Removed: $key" -Level "INFO" }
            catch { Write-Log "Could not remove $key`: $_" -Level "INFO" }
        }
    }
    Write-Log "Registry cleanup complete." -Level "INFO"
}

# -------------------------------------------------------------
#  DOWNLOAD
# -------------------------------------------------------------
function Get-DriverPackage {
    param([string]$S3Bucket, [string]$S3Key, [string]$Dest)
    if (-not (Test-Path $DownloadDir)) { New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null }
    $tmpDest = $Dest + '.part'
    try {
        # Get file size
        $amp2 = [char]38
        $sizeQuery  = "list-type=2" + $amp2 + "prefix=$([Uri]::EscapeDataString($S3Key))" + $amp2 + "max-keys=1"
        $sizeUrl    = "https://$S3Bucket.s3.amazonaws.com/?$sizeQuery"
        $sizeHdrs   = @{}
        if ($script:AwsCreds) {
            $sizeHdrs = Get-SigV4Headers -Method 'GET' -Bucket $S3Bucket -Path '/' -Query "?$sizeQuery" -Creds $script:AwsCreds
        }
        $sizeResp = Invoke-WebRequest -Uri $sizeUrl -Headers $sizeHdrs -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue
        $total = 0
        if ($sizeResp) {
            [xml]$sxml = $sizeResp.Content
            $sz = $sxml.ListBucketResult.Contents | Select-Object -ExpandProperty Size -First 1
            if ($sz) { $total = [long]$sz }
        }

        # Download via HttpWebRequest for stream progress
        $dlUrl  = "https://$S3Bucket.s3.amazonaws.com/$S3Key"
        $dlHdrs = @{}
        if ($script:AwsCreds) {
            $dlHdrs = Get-SigV4Headers -Method 'GET' -Bucket $S3Bucket -Path "/$S3Key" -Query '' -Creds $script:AwsCreds
        }
        $req = [System.Net.HttpWebRequest]::Create($dlUrl)
        $req.Method  = 'GET'
        $req.Timeout = 30000
        $req.ReadWriteTimeout = 300000
        foreach ($hk in $dlHdrs.Keys) { $req.Headers[$hk] = $dlHdrs[$hk] }

        # Progress runspace
        $pbCtx = @{ Done=$false; Downloaded=0; Total=$total }
        $pbSb  = {
            param($ctx, $fname)
            $cr  = [char]13
            $lbr = [char]91
            $rbr = [char]93
            while (-not $ctx.Done) {
                if ($ctx.Total -gt 0) {
                    $pct  = [int](($ctx.Downloaded / $ctx.Total) * 100)
                    $done = [int](($ctx.Downloaded / $ctx.Total) * 30)
                    $bar  = ([string][char]0x2588 * $done).PadRight(30)
                    [Console]::Write($cr + '  ' + $lbr + $bar + $rbr + ' ' + $pct + '% ' + $fname)
                } else {
                    [Console]::Write($cr + '  Downloading ' + $fname + ' (' + [int]($ctx.Downloaded / 1048576) + ' MB)...')
                }
                Start-Sleep -Milliseconds 200
            }
            [Console]::Write($cr + (' ' * 70) + $cr)
        }
        $pbRs  = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $pbRs.Open()
        $pbPsh = [System.Management.Automation.PowerShell]::Create()
        $pbPsh.Runspace = $pbRs
        $pbPsh.AddScript($pbSb).AddArgument($pbCtx).AddArgument((Split-Path $Dest -Leaf)) | Out-Null
        $pbHandle = $pbPsh.BeginInvoke()

        $resp = $req.GetResponse()
        $src  = $resp.GetResponseStream()
        $dst  = [System.IO.File]::Open($tmpDest, [System.IO.FileMode]::Create)
        $buf  = New-Object byte[] 81920
        $n    = 0
        do {
            $n = $src.Read($buf, 0, $buf.Length)
            if ($n -gt 0) { $dst.Write($buf, 0, $n); $pbCtx.Downloaded += $n }
        } while ($n -gt 0)
        $dst.Close(); $src.Close(); $resp.Close()

        $pbCtx.Done = $true
        Start-Sleep -Milliseconds 300
        try { $pbPsh.EndInvoke($pbHandle) } catch {}
        $pbPsh.Dispose(); $pbRs.Close()

        if (Test-Path $Dest) { Remove-Item $Dest -Force }
        Move-Item $tmpDest $Dest
        Write-Log "Download complete: $Dest" -Level "INFO"
        return $true
    } catch {
        if (Test-Path $tmpDest) { Remove-Item $tmpDest -Force -ErrorAction SilentlyContinue }
        Write-Log "Download failed: $_" -Level "ERROR"
        return $false
    }
}

# -------------------------------------------------------------
#  NVIDIA CONTROL PANEL  (winget / MSIX fallback)
# -------------------------------------------------------------
function Install-NvidiaControlPanel {
    $spinCtx = Start-Spinner -Label "Installing NVIDIA Control Panel"
    $ok      = $false
    try {
        $wgCmd = Get-Command winget -ErrorAction SilentlyContinue
        if ($wgCmd) {
            $wgArgs = 'install --id 9NF8H0H7WMLT --source msstore' +
                      ' --accept-package-agreements --accept-source-agreements' +
                      ' --silent --disable-interactivity'
            $wgLog  = "$env:TEMP\winget_cp_$([System.IO.Path]::GetRandomFileName()).log"
            $proc   = Start-Process -FilePath 'cmd.exe' `
                          -ArgumentList @('/c', ("winget " + $wgArgs + " > `"" + $wgLog + "`" 2>" + [char]38 + "1")) `
                          -PassThru -WindowStyle Hidden -Wait
            $ok = ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq -1978335189)
            Write-Log "winget NVIDIA Control Panel: ExitCode $($proc.ExitCode)" -Level "INFO"
            Remove-Item $wgLog -ErrorAction SilentlyContinue
        }
        if (-not $ok -and -not $wgCmd) {
            $amp3 = [char]38
            $uri   = "https://store.rg-adguard.net/api/GetFiles?type=PackageFamilyName" + $amp3 + "url=NVIDIACorp.NVIDIAControlPanel_56jybvy8sckqj" + $amp3 + "ring=Retail" + $amp3 + "lang=en-US"
            $links = (Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 30 -ErrorAction SilentlyContinue).Links |
                     Where-Object { $_.href -match '\.msixbundle|\.appxbundle' -and $_.href -notmatch 'blockmap' } |
                     Select-Object -First 1
            if ($links) {
                $msix = Join-Path $env:TEMP 'NvidiaCP.msixbundle'
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
    Stop-Spinner -ctx $spinCtx -Done (if ($ok) { "Control Panel installed." } else { "Control Panel install skipped." }) `
        -Color (if ($ok) { "DarkCyan" } else { "DarkGray" })
    [Console]::Out.Flush()
    $script:_cpResult = $ok
}

# -------------------------------------------------------------
#  DRIVER INSTALL
# -------------------------------------------------------------
function Install-NvidiaDriver {
    param([string]$InstallerPath, [string]$Variant)
    if (-not $InstallerPath -or -not (Test-Path $InstallerPath)) {
        Write-Log "Installer not found: $InstallerPath" -Level "ERROR"
        return $false
    }
    Write-Log "Starting driver install: $InstallerPath ($Variant)" -Level "INFO"
    $driverArgs = @('-s', '-noreboot', '-clean', '-noeula')
    $spinCtx = Start-Spinner -Label "Installing driver"
    try {
        $proc = Start-Process $InstallerPath -ArgumentList $driverArgs -PassThru -NoNewWindow
        while (-not $proc.HasExited) { Start-Sleep -Milliseconds 500 }
        Stop-Spinner -ctx $spinCtx -Done "Driver installed. Exit code: $($proc.ExitCode)." -Color "DarkCyan"
        Write-Log "Driver install exit code: $($proc.ExitCode)" -Level "INFO"
        return ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 1)
    } catch {
        Stop-Spinner -ctx $spinCtx
        Write-Log "Driver install error: $_" -Level "ERROR"
        return $false
    }
}

# -------------------------------------------------------------
#  GAMING LICENSE  (vGPU unlock for Gaming variant)
# -------------------------------------------------------------
function Set-GamingLicense {
    try {
        $svc = Get-Service 'NvContainerLocalSystem' -ErrorAction SilentlyContinue
        if ($svc) {
            $licPath = "$env:ProgramFiles\NVIDIA Corporation\vGPU Licensing\ClientConfigToken"
            if (-not (Test-Path $licPath)) { New-Item -ItemType Directory -Path $licPath -Force | Out-Null }
            # Remove any existing GRID tokens
            Get-ChildItem $licPath -Filter '*.tok' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            Write-Log "Gaming license path prepared." -Level "INFO"
        }
    } catch { Write-Log "Gaming license setup: $_" -Level "INFO" }
}

# -------------------------------------------------------------
#  REBOOT
# -------------------------------------------------------------
function Request-Reboot {
    param([int]$DelaySeconds = 10)
    Write-Host ""
    Write-Host "  Rebooting in $DelaySeconds seconds..." -ForegroundColor Yellow
    Write-Host "  Press Ctrl+C to cancel." -ForegroundColor DarkGray
    Write-Host ""
    Start-Sleep -Seconds $DelaySeconds
    Write-Log "Initiating reboot." -Level "INFO"
    Restart-Computer -Force
}

# -------------------------------------------------------------
#  STEP: SHOW STATUS
# -------------------------------------------------------------
function Step-ShowStatus {
    Write-Log "[TIMING] Detecting GPU..." -Level "INFO"
    $spinCtx = Start-Spinner -Label "Detecting GPU"
    $info    = Get-InstalledNvidiaInfo
    Stop-Spinner -ctx $spinCtx
    Write-Log "[TIMING] GPU detect done: $($info.GpuName)" -Level "INFO"
    if (-not $info.Installed) {
        Write-Host "  No NVIDIA driver detected." -ForegroundColor Red
        Write-Log "No NVIDIA driver detected" -Level "WARN"
        return $info
    }
    $vc = switch ($info.Variant) { 'Gaming'{'DarkCyan'} 'GRID'{'DarkCyan'} default{'Gray'} }
    Write-Host "  $($info.GpuName)" -ForegroundColor White
    Write-Host "  $($info.Variant) $($info.Version)" -ForegroundColor $vc
    Write-Host ""
    Write-Log "GPU: $($info.GpuName) | Driver: $($info.Version) | Variant: $($info.Variant) | Date: $($info.DriverDate)" -Level "INFO"
    return $info
}

# -------------------------------------------------------------
#  STEP: CHECK ONLINE
# -------------------------------------------------------------
function Step-CheckOnline {
    param($info)
    # S3 versions already prefetched at startup -- just read cache
    $latestGaming = if ($script:S3CacheGaming) { $script:S3CacheGaming } else { Get-LatestGamingVersion }
    $latestGrid   = if ($script:S3CacheGrid)   { $script:S3CacheGrid }   else { Get-LatestGridVersion }
    $updateAvailable = $false
    $updateVersion   = ''
    try {
        $latest = if ($info.Variant -eq 'GRID') { $latestGrid.Version } else { $latestGaming.Version }
        if ($latest -and $latest -ne 'Unknown' -and [Version]$latest -gt [Version]$info.Version) {
            $updateAvailable = $true
            $updateVersion   = $latest
        }
    } catch {}
    Write-Log "Version check -- Installed: $($info.Version) [$($info.Variant)] | Gaming: $($latestGaming.Version) | GRID: $($latestGrid.Version)" -Level "INFO"

    $s3err = ($latestGaming.Error -and $latestGrid.Error)
    if ($s3err) {
        Write-Host "  [!] Could not reach update server." -ForegroundColor Yellow
    } elseif ($updateAvailable) {
        Write-Host "  $([char]0x2191) $($info.Variant) $updateVersion available" -ForegroundColor Yellow
    } else {
        Write-Host "  $([char]0x2713) Current $($info.Variant) driver is up to date." -ForegroundColor White
    }
    Write-Host ""
    return @{ UpdateAvailable=$updateAvailable; LatestGaming=$latestGaming; LatestGrid=$latestGrid }
}

# -------------------------------------------------------------
#  STEP: ACTION MENU
# -------------------------------------------------------------
function Step-ActionMenu {
    param($info, $online)
    [string[]]$opts = @()
    if ($online.UpdateAvailable) {
        $targetVer = if ($info.Variant -eq 'GRID') { $online.LatestGrid.Version } else { $online.LatestGaming.Version }
        $opts += 'Update driver  (' + $info.Variant + ' ' + $info.Version + ' -> ' + $targetVer + ')'
    }
    if ($info.Variant -eq 'Gaming') {
        $opts += 'Switch to GRID / Enterprise driver'
    }
    if ($info.Variant -eq 'GRID') {
        if (Test-GamingDriverSupported -GpuName $info.GpuName) {
            $opts += 'Switch to Gaming / GeForce driver'
        } else {
            Write-Host "  `[i`] $($info.GpuName) supports GRID only -- Gaming driver not available for this GPU." -ForegroundColor DarkGray
            Write-Host ""
        }
    }
    if (-not $online.UpdateAvailable) {
        $opts += 'Reinstall current driver  (' + $info.Version + ')'
    }

    $sel = Prompt-Menu "What would you like to do?" @($opts)
    if ($sel -eq 0) {
        Write-Host "  Cancelled." -ForegroundColor White
        return $null
    }
    return $opts[$sel - 1]
}

# -------------------------------------------------------------
#  FULL INSTALL FLOW
#  Steps: FRESH -> AFTER_DOWNLOAD -> AFTER_UNINSTALL_AND_CLEANUP -> done
#  Single reboot (after uninstall + cleanup combined).
# -------------------------------------------------------------
function Invoke-FullInstall {
    param([string]$TargetVariant, [string]$Version, [string]$S3Bucket = '', [string]$S3Key = '')

    $installerName = "nvidia-driver-$Version-$TargetVariant.exe"
    $installerPath = Join-Path $DownloadDir $installerName

    # ── STEP 1/3: Download ────────────────────────────────────
    $state = Load-State
    if (-not $state -or $state.Step -eq 'FRESH') {
        Write-Host ""
        Write-Host "  Step 1/3  Downloading $TargetVariant driver $Version..." -ForegroundColor DarkCyan
        Write-Host ""

        if (-not $S3Key) {
            Write-Host "  [!] No S3 key available -- cannot download." -ForegroundColor Red
            Write-Log "No S3 key for download. Bucket=$S3Bucket" -Level "ERROR"
            return
        }

        Save-State @{ Step='AFTER_DOWNLOAD'; Variant=$TargetVariant; Version=$Version;
                      S3Bucket=$S3Bucket; S3Key=$S3Key; InstallerPath=$installerPath }
        Register-ResumeOnBoot -Exe $ExePath

        $ok = Get-DriverPackage -S3Bucket $S3Bucket -S3Key $S3Key -Dest $installerPath
        if (-not $ok) {
            Clear-State
            Write-Host "  Download failed. Nothing was changed." -ForegroundColor Red
            Write-Log "Download failed -- aborting install." -Level "ERROR"
            return
        }
        Write-Host "  Download complete." -ForegroundColor White
    }

    # ── STEP 2/3: Uninstall + Registry Cleanup + Reboot ──────
    $state = Load-State
    if ($state -and $state.Step -eq 'AFTER_DOWNLOAD') {
        Write-Host ""
        Write-Host "  Step 2/3  Uninstalling current driver..." -ForegroundColor DarkCyan
        Write-Host ""
        Save-State @{ Step='AFTER_UNINSTALL_AND_CLEANUP'; Variant=$state.Variant;
                      Version=$state.Version; S3Bucket=$state.S3Bucket; S3Key=$state.S3Key;
                      InstallerPath=$state.InstallerPath }

        $spinCtx = Start-Spinner -Label "Uninstalling"
        Invoke-NvidiaUninstall
        Stop-Spinner -ctx $spinCtx -Done "Uninstall complete." -Color "DarkCyan"

        $spinCtx = Start-Spinner -Label "Cleaning registry"
        Invoke-RegistryCleanup
        Stop-Spinner -ctx $spinCtx -Done "Registry clean." -Color "DarkCyan"

        Write-Host ""
        Write-Host "  Step 2/3 complete. Rebooting to apply changes..." -ForegroundColor Yellow
        Write-Host "  Driver will be installed automatically after reboot." -ForegroundColor DarkGray
        Write-Host ""
        Start-Sleep -Seconds 3
        Request-Reboot -DelaySeconds 7
        return
    }

    # ── STEP 3/3: Install ─────────────────────────────────────
    $state = Load-State
    if ($state -and $state.Step -eq 'AFTER_UNINSTALL_AND_CLEANUP') {
        $instPath = $state.InstallerPath
        $variant  = $state.Variant
        $ver      = $state.Version

        Write-Host ""
        Write-Host "  Step 3/3  Installing $variant driver $ver..." -ForegroundColor DarkCyan
        Write-Host ""

        if (-not (Test-Path $instPath)) {
            Write-Host "  [!] Installer not found: $instPath" -ForegroundColor Red
            Write-Log "Installer missing post-reboot: $instPath" -Level "ERROR"
            Clear-State
            return
        }

        $ok = Install-NvidiaDriver -InstallerPath $instPath -Variant $variant

        if ($ok -and $variant -eq 'Gaming') {
            Set-GamingLicense
            Install-NvidiaControlPanel
        }

        Clear-State
        Invoke-Cleanup

        if ($ok) {
            Write-Host ""
            Write-Host "  $([char]0x2713) $variant driver $ver installed successfully." -ForegroundColor DarkCyan
            Write-Host ""
            Write-Host "  A final reboot is recommended." -ForegroundColor DarkGray
            Write-Log "Install complete: $variant $ver" -Level "INFO"
        } else {
            Write-Host "  [!] Install may have failed -- check Device Manager." -ForegroundColor Yellow
            Write-Log "Install possibly failed." -Level "WARN"
        }
    }
}

# -------------------------------------------------------------
#  ENTRY POINT
# -------------------------------------------------------------
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8
chcp 65001 | Out-Null

foreach ($dir in @($WorkDir, $DownloadDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

Show-Banner

if ($DebugS3) {
    Write-Host "  [DEBUG] Testing S3 connectivity..." -ForegroundColor Yellow
    Write-Host ""
    $creds = Get-AwsCreds
    Write-Host "  Creds: $(if($creds){"Key=$($creds.Key.Substring(0,[Math]::Min(8,$creds.Key.Length)))... Token=$(if($creds.Token){'yes'}else{'none'})"}else{'NONE'})" -ForegroundColor DarkCyan
    Write-Host ""

    foreach ($t in @(
        @{Bucket='nvidia-gaming';              Prefix='windows/latest/'},
        @{Bucket='ec2-windows-nvidia-drivers'; Prefix='latest/'}
    )) {
        Write-Host "  Testing s3://$($t.Bucket)/$($t.Prefix)..." -ForegroundColor Yellow -NoNewline
        $r = Get-S3DriverInfo -Bucket $t.Bucket -Prefix $t.Prefix -Creds $creds
        if ($r.Error) {
            Write-Host " FAIL" -ForegroundColor Red
            Write-Host "    Error: $($r.ErrorMsg)" -ForegroundColor Red
        } else {
            Write-Host " OK  -> $($r.Version)  key=$($r.S3Key)" -ForegroundColor DarkCyan
        }
        Write-Host ""
    }

    # Also test unsigned (public access)
    Write-Host "  Testing unsigned (public) access..." -ForegroundColor Yellow
    foreach ($url in @(
        ("https://ec2-windows-nvidia-drivers.s3.amazonaws.com/?list-type=2" + [char]38 + "prefix=latest/" + [char]38 + "max-keys=5"),
        ("https://nvidia-gaming.s3.amazonaws.com/?list-type=2" + [char]38 + "prefix=windows/latest/" + [char]38 + "max-keys=5")
    )) {
        Write-Host "  GET $($url.Substring(0,60))..." -NoNewline
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            Write-Host " HTTP $($r.StatusCode)" -ForegroundColor DarkCyan
        } catch {
            Write-Host " FAIL: $_" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "  Press any key to exit..." -ForegroundColor DarkGray
    $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
    exit 0
}

Write-Log "[TIMING] Script start" -Level "INFO"

# Check for resume state before doing any network work
$existingState = Load-State
$isResume = $existingState -and $existingState.Step -in @('AFTER_DOWNLOAD','AFTER_UNINSTALL_AND_CLEANUP','UNINSTALLING')

# Load credentials + prefetch S3 in parallel via runspaces (no Start-Job / no new process)
if (-not $isResume) {
    Write-Log "[TIMING] Getting AWS creds..." -Level "INFO"
    $script:AwsCreds = Get-AwsCreds
    Write-Log "[TIMING] AWS creds done. Key=$(if($script:AwsCreds){'found'}else{'none'})" -Level "INFO"

    # Inline scriptblock for S3 fetch -- self-contained, used by both runspaces
    $fetchSb = {
        param($bucket, $prefix, $credsKey, $credsSecret, $credsToken)

        function _SHA256 { param([string]$s)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            [BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))).Replace('-','').ToLower()
        }
        function _HMAC { param([byte[]]$key, [string]$data)
            (New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList @(,$key)).ComputeHash([System.Text.Encoding]::UTF8.GetBytes($data))
        }

        try {
            $region  = 'us-east-1'
            $now     = [DateTime]::UtcNow
            $amzDate = $now.ToString('yyyyMMddTHHmmssZ')
            $date    = $now.ToString('yyyyMMdd')
            $bHash   = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
            $ampD = [char]38
        $query   = "list-type=2" + $ampD + "prefix=$([Uri]::EscapeDataString($prefix))" + $ampD + "max-keys=20"
            $url     = "https://$bucket.s3.amazonaws.com/?$query"

            $hdrs = @{}
            if ($credsKey) {
                $cHdrs  = "host:$bucket.s3.amazonaws.com`nx-amz-content-sha256:$bHash`nx-amz-date:$amzDate`n"
                $sHdrs  = 'host;x-amz-content-sha256;x-amz-date'
                if ($credsToken) { $cHdrs += "x-amz-security-token:$credsToken`n"; $sHdrs += ';x-amz-security-token' }
                $cReq   = "GET`n/`n$query`n$cHdrs`n$sHdrs`n$bHash"
                $scope  = "$date/$region/s3/aws4_request"
                $sts    = "AWS4-HMAC-SHA256`n$amzDate`n$scope`n$(_SHA256 $cReq)"
                $sigKey = _HMAC (_HMAC (_HMAC (_HMAC ([System.Text.Encoding]::UTF8.GetBytes("AWS4$credsSecret")) $date) $region) 's3') 'aws4_request'
                $sig    = [BitConverter]::ToString((New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList @(,$sigKey)).ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sts))).Replace('-','').ToLower()
                $hdrs   = @{
                    'x-amz-date'           = $amzDate
                    'x-amz-content-sha256' = $bHash
                    'Authorization'        = "AWS4-HMAC-SHA256 Credential=$credsKey/$scope,SignedHeaders=$sHdrs,Signature=$sig"
                }
                if ($credsToken) { $hdrs['x-amz-security-token'] = $credsToken }
            }

            $resp = Invoke-WebRequest -Uri $url -Headers $hdrs -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            [xml]$xml = $resp.Content
            $key = $xml.ListBucketResult.Contents | Where-Object { $_.Key -like '*.exe' } | Select-Object -ExpandProperty Key -First 1
            if ($key -and ($key -match '(\d+\.\d+)')) {
                return @{ Version=$Matches[1]; S3Key=$key; S3Bucket=$bucket; Error=$false }
            }
            return @{ Version='Unknown'; S3Key=''; S3Bucket=$bucket; Error=$false }
        } catch {
            return @{ Version='Unknown'; S3Key=''; S3Bucket=$bucket; Error=$true; ErrorMsg=$_.ToString() }
        }
    }

    # Unpack creds to primitives for runspace serialization
    $ck = if ($script:AwsCreds) { $script:AwsCreds.Key }    else { '' }
    $cs = if ($script:AwsCreds) { $script:AwsCreds.Secret } else { '' }
    $ct = if ($script:AwsCreds) { $script:AwsCreds.Token }  else { '' }

    $rsG = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rsR = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rsG.Open(); $rsR.Open()

    $pshG = [System.Management.Automation.PowerShell]::Create(); $pshG.Runspace = $rsG
    $pshG.AddScript($fetchSb).AddArgument('nvidia-gaming').AddArgument('windows/latest/').AddArgument($ck).AddArgument($cs).AddArgument($ct) | Out-Null
    $pshR = [System.Management.Automation.PowerShell]::Create(); $pshR.Runspace = $rsR
    $pshR.AddScript($fetchSb).AddArgument('ec2-windows-nvidia-drivers').AddArgument('latest/').AddArgument($ck).AddArgument($cs).AddArgument($ct) | Out-Null

    Write-Log "[TIMING] Starting S3 runspaces..." -Level "INFO"
    $_loadCtx = Start-Spinner -Label "Loading"
    $hG = $pshG.BeginInvoke()
    $hR = $pshR.BeginInvoke()
    while (-not $hG.IsCompleted -or -not $hR.IsCompleted) { Start-Sleep -Milliseconds 100 }
    Stop-Spinner -ctx $_loadCtx
    Write-Log "[TIMING] S3 runspaces done" -Level "INFO"

    $script:S3CacheGaming = $pshG.EndInvoke($hG)[0]
    $script:S3CacheGrid   = $pshR.EndInvoke($hR)[0]
    $pshG.Dispose(); $rsG.Close()
    $pshR.Dispose(); $rsR.Close()

    if (-not $script:S3CacheGaming) { $script:S3CacheGaming = @{ Version='Unknown'; S3Key=''; S3Bucket='nvidia-gaming'; Error=$true } }
    if (-not $script:S3CacheGrid)   { $script:S3CacheGrid   = @{ Version='Unknown'; S3Key=''; S3Bucket='ec2-windows-nvidia-drivers'; Error=$true } }

    Write-Log "[TIMING] S3 Gaming=$(if($script:S3CacheGaming.Error){'ERROR: '+$script:S3CacheGaming.ErrorMsg}else{$script:S3CacheGaming.Version}) Grid=$(if($script:S3CacheGrid.Error){'ERROR: '+$script:S3CacheGrid.ErrorMsg}else{$script:S3CacheGrid.Version})" -Level "INFO"

    if ($script:S3CacheGaming.Error -and $script:S3CacheGrid.Error) {
        Write-Host ""
        Write-Host "  [!] Cannot reach AWS S3 -- driver downloads will not be available." -ForegroundColor Yellow
        Write-Host "      Check: C:\Users\user\.aws\credentials" -ForegroundColor DarkGray
        Write-Host ""
    }
}

# ── Resume path ───────────────────────────────────────────────
if ($isResume) {
    Write-Host ""
    $stepDesc = switch ($existingState.Step) {
        'AFTER_DOWNLOAD'               { 'Resuming: uninstall + reboot' }
        'AFTER_UNINSTALL_AND_CLEANUP'  { 'Resuming: install driver' }
        default                        { 'Resuming...' }
    }
    Write-Host "  $stepDesc" -ForegroundColor Yellow
    Write-Host ""
    Invoke-FullInstall -TargetVariant $existingState.Variant `
                       -Version       $existingState.Version `
                       -S3Bucket      $existingState.S3Bucket `
                       -S3Key         $existingState.S3Key
    Write-Host "  Press any key to exit..." -ForegroundColor DarkGray
    $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
    exit 0
}

# ── Normal interactive flow ───────────────────────────────────
$info   = Step-ShowStatus
if (-not $info.Installed) {
    Write-Host "  Press any key to exit..." -ForegroundColor DarkGray
    $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
    Invoke-Cleanup
    exit 0
}

$online = Step-CheckOnline -info $info
$action = Step-ActionMenu  -info $info -online $online

if (-not $action) {
    Invoke-Cleanup
    exit 0
}

# Determine target variant and S3 info
$targetVariant = $info.Variant
$targetVersion = ''
$targetBucket  = ''
$targetKey     = ''

if ($action -match 'Update') {
    $targetVariant = $info.Variant
    if ($info.Variant -eq 'GRID') {
        $targetVersion = $online.LatestGrid.Version
        $targetBucket  = $online.LatestGrid.S3Bucket
        $targetKey     = $online.LatestGrid.S3Key
    } else {
        $targetVersion = $online.LatestGaming.Version
        $targetBucket  = $online.LatestGaming.S3Bucket
        $targetKey     = $online.LatestGaming.S3Key
    }
} elseif ($action -match 'GRID') {
    $targetVariant = 'GRID'
    $targetVersion = $online.LatestGrid.Version
    $targetBucket  = $online.LatestGrid.S3Bucket
    $targetKey     = $online.LatestGrid.S3Key
} elseif ($action -match 'Gaming') {
    $targetVariant = 'Gaming'
    $targetVersion = $online.LatestGaming.Version
    $targetBucket  = $online.LatestGaming.S3Bucket
    $targetKey     = $online.LatestGaming.S3Key
} elseif ($action -match 'Reinstall') {
    $targetVariant = $info.Variant
    $targetVersion = $info.Version
    if ($info.Variant -eq 'GRID') {
        $targetBucket = $online.LatestGrid.S3Bucket
        $targetKey    = $online.LatestGrid.S3Key
    } else {
        $targetBucket = $online.LatestGaming.S3Bucket
        $targetKey    = $online.LatestGaming.S3Key
    }
}

if (-not $targetVersion -or $targetVersion -eq 'Unknown') {
    Write-Host "  [!] Version not available -- check S3 connection." -ForegroundColor Yellow
    Write-Host "  Press any key to exit..." -ForegroundColor DarkGray
    $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
    Invoke-Cleanup
    exit 0
}

Write-Host ""
Write-Host "  $targetVariant $targetVersion will be installed." -ForegroundColor DarkCyan
Write-Host "  This will uninstall the current driver and reboot." -ForegroundColor DarkGray
Write-Host ""
$confirm = Prompt-YesNo "Continue?"
if (-not $confirm) {
    Write-Host "  Cancelled." -ForegroundColor White
    Invoke-Cleanup
    exit 0
}

Invoke-FullInstall -TargetVariant $targetVariant `
                   -Version       $targetVersion `
                   -S3Bucket      $targetBucket `
                   -S3Key         $targetKey

Write-Host ""
Write-Host "  Press any key to exit..." -ForegroundColor DarkGray
$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
Invoke-Cleanup
exit 0

# -------------------------------------------------------------
#  DEBUG: Run this manually to test S3 connectivity
#  Usage: .\Manage-NvidiaDriver-v2.ps1 -DebugS3
# -------------------------------------------------------------
# (Append this to the bottom -- call with: powershell -File script.ps1 -DebugS3)
