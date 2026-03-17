#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs Amazon DCV Server IDD for full 4K resolution, then disables all
    other display adapters so only the DCV virtual monitor remains.

.DESCRIPTION
    1. Installs Amazon DCV Server silently (IDD only, no DCV sessions/client)
    2. Reboots if required by installer (only if necessary)
    3. After IDD is confirmed active:
       - Disables Microsoft Basic Display Adapter
       - Disables NVIDIA display output (keeps NVIDIA as render GPU, just removes
         it as a Windows display adapter so DCV IDD is the sole active monitor)
       - Disables any other virtual display adapters (SudoMaker, Parsec etc.)
    4. Sets DCV display to 3840x2160

    The NVIDIA Tesla/GPU remains fully active for rendering and CUDA --
    only its role as a *Windows display adapter* is removed.
    Users connect via RDP / Parsec / Moonlight as before.

.NOTES
    Free on EC2. Requires Windows Server 2019+. Reboot may be needed once.
#>

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'

# ── Config ──────────────────────────────────────────────────────────────────
$WorkDir    = "$env:ProgramFiles\airgpu\DCV"
$LogFile    = "$env:ProgramData\airgpu\dcv_install.log"
$DcvBaseUrl = 'https://d1uj6qtbmh3dt5.cloudfront.net'
$DcvMsiUrl  = "$DcvBaseUrl/nice-dcv-server-x64-Release.msi"
$DcvMsiDest = Join-Path $WorkDir 'dcv-server.msi'
$RebootFlag = Join-Path $WorkDir 'pending_reboot'

# Display adapters to disable after IDD is active.
# These are matched against FriendlyName (case-insensitive, wildcard).
# The DCV IDD ("AWS Indirect Display Device") is explicitly excluded.
$DisablePatterns = @(
    '*Microsoft Basic Display*',
    '*SudoMaker*',
    '*Parsec Virtual Display*',
    '*Parsec Virtual USB*',
    '*IddSample*',
    '*Virtual Display*',
    '*NVIDIA Tesla*',     # NVIDIA display adapter role (not the compute device)
    '*NVIDIA T4*',
    '*NVIDIA A10*',
    '*NVIDIA L4*',
    '*NVIDIA L40*'
)

# ── Logging ─────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Msg"
    try {
        $d = Split-Path $LogFile
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch {}
    switch ($Level) {
        'WARN'  { Write-Host "  [!] $Msg" -ForegroundColor Yellow }
        'ERROR' { Write-Host "  [!] $Msg" -ForegroundColor Red }
        default { Write-Host "      $Msg" -ForegroundColor DarkGray }
    }
}

# ── Download with redirect support ──────────────────────────────────────────
function Get-FileFromWeb {
    param([string]$Url, [string]$Dest)
    Write-Log "Downloading $(Split-Path $Url -Leaf) ..."
    $tmp = $Dest + '.part'
    foreach ($attempt in 1..3) {
        try {
            $current = $Url
            for ($r = 0; $r -lt 10; $r++) {
                $req = [System.Net.HttpWebRequest]::Create($current)
                $req.UserAgent        = 'airgpu-dcv/1.0'
                $req.Timeout          = 60000
                $req.ReadWriteTimeout = 600000
                $req.AllowAutoRedirect = $false
                $resp = $req.GetResponse()
                if ([int]$resp.StatusCode -in @(301,302,303,307,308)) {
                    $current = $resp.Headers['Location']
                    $resp.Close(); continue
                }
                $stream = $resp.GetResponseStream()
                $fs     = [System.IO.File]::Create($tmp)
                $buf    = New-Object byte[] 65536
                $read   = 0
                while (($read = $stream.Read($buf, 0, $buf.Length)) -gt 0) { $fs.Write($buf, 0, $read) }
                $fs.Close(); $stream.Close(); $resp.Close()
                break
            }
            if (Test-Path $Dest) { Remove-Item $Dest -Force }
            Rename-Item $tmp $Dest
            Write-Log ("  OK (" + ('{0:N1}' -f ((Get-Item $Dest).Length / 1MB)) + " MB)")
            return
        } catch {
            Write-Log "  Attempt $attempt failed: $_" -Level 'WARN'
            if (Test-Path $tmp) { try { Remove-Item $tmp -Force } catch {} }
            if ($attempt -lt 3) { Start-Sleep -Seconds (3 * $attempt) }
        }
    }
    throw "Download failed: $Url"
}

# ── Check if DCV IDD is already active ──────────────────────────────────────
function Test-DCVIddActive {
    try {
        $dev = Get-PnpDevice -ErrorAction SilentlyContinue |
               Where-Object { $_.FriendlyName -like '*AWS Indirect*' -or
                               $_.FriendlyName -like '*DCV*' } |
               Where-Object { $_.Status -eq 'OK' }
        return ($null -ne $dev)
    } catch { return $false }
}

# ── Banner ───────────────────────────────────────────────────────────────────
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Host ''
Write-Host '  airgpu -- DCV Display Fix + Display Cleanup' -ForegroundColor DarkCyan
Write-Host '  Installs DCV IDD, then disables all other display adapters.' -ForegroundColor DarkGray
Write-Host ''

if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
Write-Log "=== Script start ==="
Write-Log "WorkDir: $WorkDir"

# ── Phase 1: Is this a post-reboot resume? ──────────────────────────────────
$isResume = Test-Path $RebootFlag
if ($isResume) {
    Write-Host '  Resuming after reboot...' -ForegroundColor DarkCyan
    Write-Log "Post-reboot resume detected."
    Remove-Item $RebootFlag -Force -ErrorAction SilentlyContinue
} else {
    # ── Phase 1a: Check OS version ─────────────────────────────────────────
    $build = [System.Environment]::OSVersion.Version.Build
    Write-Log "OS build: $build (need 17763+ for IDD)"
    if ($build -lt 17763) {
        Write-Log "Windows Server 2019+ required (build 17763+). Got: $build" -Level 'ERROR'
        Write-Host '  [!] Windows Server 2019 or later required.' -ForegroundColor Red
        exit 1
    }

    # ── Phase 1b: Install DCV if IDD not yet active ────────────────────────
    Write-Host '  [1/3] Checking DCV installation...' -ForegroundColor DarkCyan
    if (Test-DCVIddActive) {
        Write-Log "DCV IDD already active -- skipping install."
        Write-Host '      DCV IDD already active.' -ForegroundColor DarkGray
    } else {
        Write-Host '      DCV not yet installed. Downloading...' -ForegroundColor DarkGray

        # Download
        try {
            Get-FileFromWeb -Url $DcvMsiUrl -Dest $DcvMsiDest
        } catch {
            Write-Log "Latest URL failed, trying pinned version..." -Level 'WARN'
            Get-FileFromWeb -Url "$DcvBaseUrl/2025.0/Servers/nice-dcv-server-x64-Release-2025.0-20103.msi" -Dest $DcvMsiDest
        }

        # Install -- IDD only, no sessions, no firewall
        Write-Host '      Installing (silent)...' -ForegroundColor DarkGray
        $msiLog  = Join-Path $WorkDir 'dcv_msi.log'
        $msiArgs = @(
            '/i', $DcvMsiDest,
            'DISABLE_AUTOMATIC_SESSION_CREATION=1',
            '/quiet', '/norestart',
            ('/l*v "' + $msiLog + '"')
        )
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -PassThru -Wait
        Write-Log "msiexec exit: $($p.ExitCode)"

        if ($p.ExitCode -eq 3010) {
            # Reboot required -- save flag, schedule script to re-run after reboot
            Write-Log "Reboot required by installer. Scheduling resume..."
            Set-Content -Path $RebootFlag -Value (Get-Date) -Encoding UTF8

            # Register script to re-run after reboot via RunOnce
            $scriptPath = $MyInvocation.MyCommand.Path
            if ($scriptPath) {
                $runOncePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
                $cmd = 'powershell.exe -ExecutionPolicy Bypass -File "' + $scriptPath + '"'
                Set-ItemProperty -Path $runOncePath -Name 'airgpuDCVResume' -Value $cmd -Force
                Write-Log "RunOnce registered: $cmd"
            }

            Write-Host ''
            Write-Host '  Reboot required to complete DCV installation.' -ForegroundColor Yellow
            Write-Host '  The script will automatically continue after reboot.' -ForegroundColor Yellow
            Write-Host ''
            Write-Host '  Rebooting in 10 seconds... (Ctrl+C to cancel)' -ForegroundColor Yellow
            Start-Sleep -Seconds 10
            Restart-Computer -Force
            exit 0
        } elseif ($p.ExitCode -ne 0) {
            Write-Log "Installer returned $($p.ExitCode) -- see $msiLog" -Level 'WARN'
            Write-Host "  [!] Installer returned $($p.ExitCode)" -ForegroundColor Yellow
        } else {
            Write-Log "DCV installed successfully (no reboot needed)."
        }

        # Disable DCV server service -- we only need the IDD driver
        try {
            Stop-Service  'dcvserver' -Force -ErrorAction SilentlyContinue
            Set-Service   'dcvserver' -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Log "DCV server service disabled."
        } catch {}

        Start-Sleep -Seconds 3
    }
}

# ── Phase 2: Verify IDD is present ──────────────────────────────────────────
Write-Host '  [2/3] Verifying DCV Indirect Display Driver...' -ForegroundColor DarkCyan
$dcvIdd = $null
for ($wait = 0; $wait -lt 5; $wait++) {
    $dcvIdd = Get-PnpDevice -ErrorAction SilentlyContinue |
              Where-Object { $_.FriendlyName -like '*AWS Indirect*' -or
                              ($_.FriendlyName -like '*DCV*' -and $_.Class -eq 'Display') }
    if ($dcvIdd) { break }
    Start-Sleep -Seconds 2
}

if (-not $dcvIdd) {
    Write-Log "DCV IDD not found. May need reboot." -Level 'WARN'
    Write-Host '  [!] DCV IDD not detected -- try rebooting manually and re-running.' -ForegroundColor Yellow
} else {
    Write-Log "DCV IDD confirmed: $($dcvIdd.FriendlyName) [$($dcvIdd.Status)]"
    Write-Host "      IDD active: $($dcvIdd.FriendlyName)" -ForegroundColor DarkCyan
}

# ── Phase 3: Disable all other display adapters ──────────────────────────────
Write-Host '  [3/3] Disabling other display adapters...' -ForegroundColor DarkCyan

$allDisplayDevices = Get-PnpDevice -Class 'Display' -ErrorAction SilentlyContinue |
                     Where-Object { $_.Status -eq 'OK' }

Write-Log "Active display devices found: $($allDisplayDevices.Count)"
foreach ($dev in $allDisplayDevices) {
    Write-Log "  Found: '$($dev.FriendlyName)' [$($dev.InstanceId)]"
}

$disabled = 0
foreach ($dev in $allDisplayDevices) {
    # Skip DCV IDD -- this is the one we want to keep
    if ($dev.FriendlyName -like '*AWS Indirect*' -or
        $dev.FriendlyName -like '*Indirect Display*' -or
        ($dev.FriendlyName -like '*DCV*' -and $dev.FriendlyName -notlike '*Parsec*')) {
        Write-Log "  Keeping: $($dev.FriendlyName)"
        continue
    }

    # Check if this device matches any disable pattern
    $shouldDisable = $false
    foreach ($pattern in $DisablePatterns) {
        if ($dev.FriendlyName -like $pattern) {
            $shouldDisable = $true
            break
        }
    }

    # Also disable anything in Display class that isn't the DCV IDD
    # (catches any display adapter we didn't explicitly list)
    if (-not $shouldDisable) {
        $shouldDisable = $true  # disable all display adapters except DCV IDD
    }

    if ($shouldDisable) {
        try {
            Disable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop
            Write-Log "  Disabled: $($dev.FriendlyName)"
            Write-Host ("      Disabled: " + $dev.FriendlyName) -ForegroundColor DarkGray
            $disabled++
        } catch {
            Write-Log "  Could not disable '$($dev.FriendlyName)': $_" -Level 'WARN'
            Write-Host ("  [!] Could not disable: " + $dev.FriendlyName) -ForegroundColor Yellow
        }
    }
}
Write-Log "Disabled $disabled display adapter(s)."

# ── Set DCV display resolution ───────────────────────────────────────────────
Write-Log "Setting DCV display resolution to 3840x2160..."
try {
    $regPath = 'HKEY_USERS\S-1-5-18\Software\GSettings\com\nicesoftware\dcv\display'
    reg.exe add $regPath /v 'console-session-default-layout' /t REG_SZ /d "[{'w':3840,'h':2160,'x':0,'y':0}]" /f 2>&1 | Out-Null
    reg.exe add $regPath /v 'min-head-resolution' /t REG_SZ /d "(1920, 1080)" /f 2>&1 | Out-Null
    Write-Log "Resolution registry keys set."
} catch { Write-Log "Resolution registry error: $_" -Level 'WARN' }

try {
    if (Get-Command Set-DisplayResolution -ErrorAction SilentlyContinue) {
        Set-DisplayResolution -Width 3840 -Height 2160 -Force -ErrorAction SilentlyContinue
        Write-Log "Set-DisplayResolution 3840x2160 OK."
    }
} catch { Write-Log "Set-DisplayResolution: $_" -Level 'WARN' }

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  Done.' -ForegroundColor DarkCyan
Write-Host ''
Write-Host '  DCV IDD is the only active display adapter.' -ForegroundColor White
Write-Host '  NVIDIA GPU is still active for rendering / gaming.' -ForegroundColor White
Write-Host '  RDP / Parsec / Moonlight connections are unaffected.' -ForegroundColor White
Write-Host ''

# Show current state
Write-Host '  Active display adapters now:' -ForegroundColor DarkGray
Get-PnpDevice -Class 'Display' -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host ("    " + $_.Status.PadRight(10) + $_.FriendlyName) -ForegroundColor DarkGray }

Write-Host ''
Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
Write-Host ''
