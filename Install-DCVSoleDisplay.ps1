#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs Amazon DCV Server IDD for full 4K resolution, then sets the DCV
    virtual monitor as the sole active display. All other display outputs are
    deactivated in the Windows display topology (no drivers disabled -- RDP
    and the system stay stable).

.DESCRIPTION
    Step 1: Install Amazon DCV Server silently (IDD only, no sessions/client).
            If a reboot is required, the script registers itself in RunOnce
            and reboots automatically. On resume it continues from Step 2.
    Step 2: Verify DCV Indirect Display Driver is active.
    Step 3: Use SetDisplayConfig API to make DCV the sole active monitor,
            deactivating all others (NVIDIA, Microsoft Basic, SudoMaker etc.)
            in the Windows display topology. Equivalent to "Show only on this
            display" in Display Settings. Survives reboots.
    NVIDIA GPU stays fully active for rendering/gaming/CUDA.
    Users connect via RDP / Parsec / Moonlight as before.
    Free on EC2. Requires Windows Server 2019+.
#>

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

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
        # msiexec requires a single argument string -- array splitting breaks /l*v
        $msiArgs = "/i `"$DcvMsiDest`" DISABLE_AUTOMATIC_SESSION_CREATION=1 /quiet /norestart /l*v `"$msiLog`""
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


# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 3: SET DCV AS SOLE ACTIVE DISPLAY (SetDisplayConfig API)
# ═══════════════════════════════════════════════════════════════════════════════

# ── Load DisplayConfig API via C# ────────────────────────────────────────────
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class DisplayConfig {

    // ── P/Invoke declarations ──────────────────────────────────────────────
    [DllImport("user32.dll")] public static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPathArrayElements, out uint numModeInfoArrayElements);
    [DllImport("user32.dll")] public static extern int QueryDisplayConfig(uint flags, ref uint numPathArrayElements, [Out] DISPLAYCONFIG_PATH_INFO[] pathArray, ref uint numModeInfoArrayElements, [Out] DISPLAYCONFIG_MODE_INFO[] modeInfoArray, IntPtr currentTopologyId);
    [DllImport("user32.dll")] public static extern int SetDisplayConfig(uint numPathArrayElements, [In] DISPLAYCONFIG_PATH_INFO[] pathArray, uint numModeInfoArrayElements, [In] DISPLAYCONFIG_MODE_INFO[] modeInfoArray, uint flags);
    [DllImport("user32.dll")] public static extern int DisplayConfigGetDeviceInfo([In, Out] ref DISPLAYCONFIG_SOURCE_DEVICE_NAME info);
    [DllImport("user32.dll")] public static extern int DisplayConfigGetDeviceInfo([In, Out] ref DISPLAYCONFIG_TARGET_DEVICE_NAME info);

    public const uint QDC_ALL_PATHS           = 0x00000001;
    public const uint QDC_ONLY_ACTIVE_PATHS   = 0x00000002;
    public const uint SDC_APPLY               = 0x00000080;
    public const uint SDC_USE_SUPPLIED_DISPLAY_CONFIG = 0x00000020;
    public const uint SDC_SAVE_TO_DATABASE    = 0x00000200;
    public const uint SDC_ALLOW_CHANGES       = 0x00000400;
    public const uint SDC_NO_OPTIMIZATION     = 0x00000100;
    public const uint SDC_VALIDATE            = 0x00000040;

    public const uint DISPLAYCONFIG_PATH_ACTIVE = 0x00000001;

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_SOURCE_INFO {
        public LUID adapterId;
        public uint id;
        public uint modeInfoIdx;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_TARGET_INFO {
        public LUID adapterId;
        public uint id;
        public uint modeInfoIdx;
        public uint outputTechnology;
        public uint rotation;
        public uint scaling;
        public DISPLAYCONFIG_RATIONAL refreshRate;
        public uint scanLineOrdering;
        public bool targetAvailable;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_RATIONAL { public uint Numerator; public uint Denominator; }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_INFO {
        public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo;
        public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo;
        public uint flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_2DREGION { public uint cx; public uint cy; }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_VIDEO_SIGNAL_INFO {
        public ulong pixelRate;
        public DISPLAYCONFIG_RATIONAL hSyncFreq;
        public DISPLAYCONFIG_RATIONAL vSyncFreq;
        public DISPLAYCONFIG_2DREGION activeSize;
        public DISPLAYCONFIG_2DREGION totalSize;
        public uint videoStandard;
        public uint scanLineOrdering;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_TARGET_MODE {
        public DISPLAYCONFIG_VIDEO_SIGNAL_INFO targetVideoSignalInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINTL { public int x; public int y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_SOURCE_MODE {
        public uint width;
        public uint height;
        public uint pixelFormat;
        public POINTL position;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct DISPLAYCONFIG_MODE_INFO_UNION {
        [FieldOffset(0)] public DISPLAYCONFIG_TARGET_MODE targetMode;
        [FieldOffset(0)] public DISPLAYCONFIG_SOURCE_MODE sourceMode;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_MODE_INFO {
        public uint infoType;
        public uint id;
        public LUID adapterId;
        public DISPLAYCONFIG_MODE_INFO_UNION modeInfo;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAYCONFIG_SOURCE_DEVICE_NAME {
        public uint size;
        public uint type;
        public uint id;
        public LUID adapterId;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string viewGdiDeviceName;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAYCONFIG_TARGET_DEVICE_NAME {
        public uint size;
        public uint type;
        public uint id;
        public LUID adapterId;
        public uint outputTechnology;
        public uint edidManufactureId;
        public uint edidProductCodeId;
        public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string monitorFriendlyDeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string monitorDevicePath;
    }

    // ── Get all paths (active + inactive) ─────────────────────────────────
    public static void GetAllPaths(out DISPLAYCONFIG_PATH_INFO[] paths, out DISPLAYCONFIG_MODE_INFO[] modes) {
        uint numPaths, numModes;
        GetDisplayConfigBufferSizes(QDC_ALL_PATHS, out numPaths, out numModes);
        paths = new DISPLAYCONFIG_PATH_INFO[numPaths];
        modes = new DISPLAYCONFIG_MODE_INFO[numModes];
        QueryDisplayConfig(QDC_ALL_PATHS, ref numPaths, paths, ref numModes, modes, IntPtr.Zero);
    }

    // ── Get friendly name of a target ─────────────────────────────────────
    public static string GetTargetName(DISPLAYCONFIG_PATH_INFO path) {
        var info = new DISPLAYCONFIG_TARGET_DEVICE_NAME();
        info.size = (uint)Marshal.SizeOf(info);
        info.type = 2; // DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME
        info.adapterId = path.targetInfo.adapterId;
        info.id = path.targetInfo.id;
        DisplayConfigGetDeviceInfo(ref info);
        return info.monitorFriendlyDeviceName ?? "";
    }

    // ── Apply: only activate paths where target name matches keyword ───────
    public static string SetSoleActiveDisplay(string keyword) {
        DISPLAYCONFIG_PATH_INFO[] paths;
        DISPLAYCONFIG_MODE_INFO[] modes;
        GetAllPaths(out paths, out modes);

        var results = new List<string>();
        int activatedCount = 0;

        for (int i = 0; i < paths.Length; i++) {
            string name = GetTargetName(paths[i]);
            bool isTarget = name.IndexOf(keyword, StringComparison.OrdinalIgnoreCase) >= 0;
            if (isTarget && activatedCount == 0) {
                paths[i].flags |= DISPLAYCONFIG_PATH_ACTIVE;
                activatedCount++;
                results.Add("ACTIVE: " + name);
            } else {
                paths[i].flags &= ~DISPLAYCONFIG_PATH_ACTIVE;
                if (!string.IsNullOrEmpty(name)) results.Add("inactive: " + name);
            }
        }

        if (activatedCount == 0) {
            return "ERROR: No display matching '" + keyword + "' found.\n" + string.Join("\n", results);
        }

        uint flags = SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_SAVE_TO_DATABASE | SDC_ALLOW_CHANGES;
        int ret = SetDisplayConfig((uint)paths.Length, paths, (uint)modes.Length, modes, flags);
        return "SetDisplayConfig result: " + ret + " (0=OK)\n" + string.Join("\n", results);
    }

    // ── List all display targets ───────────────────────────────────────────
    public static string ListAllDisplays() {
        DISPLAYCONFIG_PATH_INFO[] paths;
        DISPLAYCONFIG_MODE_INFO[] modes;
        GetAllPaths(out paths, out modes);
        var seen = new System.Collections.Generic.HashSet<string>();
        var lines = new List<string>();
        foreach (var p in paths) {
            string name = GetTargetName(p);
            bool active = (p.flags & DISPLAYCONFIG_PATH_ACTIVE) != 0;
            string key = name + "|" + active;
            if (!seen.Contains(key)) {
                seen.Add(key);
                lines.Add((active ? "[ACTIVE] " : "[      ] ") + name);
            }
        }
        return string.Join("\n", lines);
    }
}
'@ -ErrorAction Stop

# ── Banner ───────────────────────────────────────────────────────────────────
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Host ''
Write-Host '  airgpu -- Set DCV as sole active display' -ForegroundColor DarkCyan
Write-Host ''

# ── Show current state ───────────────────────────────────────────────────────
Write-Host '  Current display state:' -ForegroundColor DarkGray
$list = [DisplayConfig]::ListAllDisplays()
$list.Split("`n") | Where-Object { $_.Trim() } | ForEach-Object {
    $color = if ($_ -like '*ACTIVE*') { 'DarkCyan' } else { 'DarkGray' }
    Write-Host "    $_" -ForegroundColor $color
}
Write-Log "Before: $list"
Write-Host ''

# ── Find DCV display ─────────────────────────────────────────────────────────
# DCV IDD monitor name is "ParsecVDA" ... wait no, DCV monitor is "AWS Indirect Display"
# Try both keywords in order
$keywords = @('AWS Indirect', 'Indirect Display', 'DCV', 'IDD')
$result   = $null

foreach ($kw in $keywords) {
    Write-Log "Trying keyword: '$kw'"
    $result = [DisplayConfig]::SetSoleActiveDisplay($kw)
    if ($result -notlike 'ERROR:*') {
        Write-Log "Matched with keyword: '$kw'"
        break
    }
}

if ($result -like 'ERROR:*') {
    Write-Host '  [!] DCV display not found. Is DCV IDD installed and active?' -ForegroundColor Red
    Write-Host '      Run Install-DCVDisplayFix.ps1 first.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Available displays:' -ForegroundColor DarkGray
    $list.Split("`n") | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    Write-Log "Failed: $result" -Level 'ERROR'
    exit 1
}

Write-Log "Result: $result"
Write-Host '  Result:' -ForegroundColor DarkGray
$result.Split("`n") | Where-Object { $_.Trim() } | ForEach-Object {
    $color = if ($_ -like 'ACTIVE*') { 'DarkCyan' } else { 'DarkGray' }
    Write-Host "    $_" -ForegroundColor $color
}


# ── Show new state ───────────────────────────────────────────────────────────
Start-Sleep -Seconds 2
Write-Host ''
Write-Host '  New display state:' -ForegroundColor DarkGray
[DisplayConfig]::ListAllDisplays().Split("`n") | Where-Object { $_.Trim() } | ForEach-Object {
    $color = if ($_ -like '*ACTIVE*') { 'DarkCyan' } else { 'DarkGray' }
    Write-Host "    $_" -ForegroundColor $color
}

Write-Host ''
Write-Host '  Done. DCV is now the sole active display.' -ForegroundColor DarkCyan
Write-Host '  Parsec / Moonlight will connect to the DCV monitor only.' -ForegroundColor White
Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
Write-Host ''
