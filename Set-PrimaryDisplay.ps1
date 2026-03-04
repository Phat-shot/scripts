#Requires -RunAsAdministrator
<#
.SYNOPSIS
    airgpu Display Manager -- List displays and set the primary display.

.NOTES
    Working dir : C:\Program Files\airgpu\Driver Manager\
    Log file    : C:\Program Files\airgpu\Driver Manager\driver_manager.log
#>

# ─────────────────────────────────────────────────────────────
#  CONFIG & LOGGING
# ─────────────────────────────────────────────────────────────
$WorkDir = "C:\Program Files\airgpu\Driver Manager"
$LogFile = "$WorkDir\driver_manager.log"

if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────
#  WIN32 API  (SetDisplayConfig / QueryDisplayConfig)
# ─────────────────────────────────────────────────────────────
Add-Type @"
using System;
using System.Runtime.InteropServices;

public class DisplayAPI {

    // ── Structs ──────────────────────────────────────────────
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_SOURCE_INFO {
        public LUID   adapterId;
        public uint   id;
        public uint   modeInfoIdx;
        public uint   statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_TARGET_INFO {
        public LUID   adapterId;
        public uint   id;
        public uint   modeInfoIdx;
        public int    outputTechnology;
        public int    rotation;
        public int    scaling;
        public DISPLAYCONFIG_RATIONAL refreshRate;
        public int    scanLineOrdering;
        [MarshalAs(UnmanagedType.Bool)] public bool targetAvailable;
        public uint   statusFlags;
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
        public int  scanLineOrdering;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINTL { public int x; public int y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_TARGET_MODE {
        public DISPLAYCONFIG_VIDEO_SIGNAL_INFO targetVideoSignalInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_SOURCE_MODE {
        public uint  width;
        public uint  height;
        public int   pixelFormat;
        public POINTL position;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct DISPLAYCONFIG_MODE_INFO_UNION {
        [FieldOffset(0)] public DISPLAYCONFIG_TARGET_MODE targetMode;
        [FieldOffset(0)] public DISPLAYCONFIG_SOURCE_MODE sourceMode;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_MODE_INFO {
        public int   infoType;          // 1=target, 2=source
        public uint  id;
        public LUID  adapterId;
        public DISPLAYCONFIG_MODE_INFO_UNION info;
    }

    // ── Device name query ────────────────────────────────────
    public const int DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME = 2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAYCONFIG_TARGET_DEVICE_NAME_FLAGS {
        public uint value;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAYCONFIG_DEVICE_INFO_HEADER {
        public int  type;
        public uint size;
        public LUID adapterId;
        public uint id;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAYCONFIG_TARGET_DEVICE_NAME {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public DISPLAYCONFIG_TARGET_DEVICE_NAME_FLAGS flags;
        public int  outputTechnology;
        public ushort edidManufactureId;
        public ushort edidProductCodeId;
        public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string monitorFriendlyDeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string monitorDevicePath;
    }

    // ── P/Invoke ─────────────────────────────────────────────
    [DllImport("user32.dll")] public static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPaths, out uint numModes);
    [DllImport("user32.dll")] public static extern int QueryDisplayConfig(uint flags, ref uint numPaths, [Out] DISPLAYCONFIG_PATH_INFO[] paths, ref uint numModes, [Out] DISPLAYCONFIG_MODE_INFO[] modes, IntPtr currentTopologyId);
    [DllImport("user32.dll")] public static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_TARGET_DEVICE_NAME deviceName);
    [DllImport("user32.dll")] public static extern int SetDisplayConfig(uint numPaths, [In] DISPLAYCONFIG_PATH_INFO[] paths, uint numModes, [In] DISPLAYCONFIG_MODE_INFO[] modes, uint flags);

    // ── EnumDisplayDevices ───────────────────────────────────
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DISPLAY_DEVICE {
        public int    cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public uint   StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    public const uint DISPLAY_DEVICE_ACTIVE        = 0x00000001;
    public const uint DISPLAY_DEVICE_PRIMARY_DEVICE = 0x00000004;
    public const uint DISPLAY_DEVICE_ATTACHED       = 0x00000002;

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

    // ── ChangeDisplaySettingsEx ──────────────────────────────
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public ushort dmSpecVersion; public ushort dmDriverVersion; public ushort dmSize; public ushort dmDriverExtra;
        public uint dmFields;
        public int dmPositionX; public int dmPositionY;
        public uint dmDisplayOrientation; public uint dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution;
        public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public ushort dmLogPixels; public uint dmBitsPerPel;
        public uint dmPelsWidth; public uint dmPelsHeight;
        public uint dmDisplayFlags; public uint dmDisplayFrequency;
        public uint dmICMMethod; public uint dmICMIntent; public uint dmMediaType;
        public uint dmDitherType; public uint dmReserved1; public uint dmReserved2;
        public uint dmPanningWidth; public uint dmPanningHeight;
    }

    public const int  CDS_SET_PRIMARY  = 0x00000010;
    public const int  CDS_UPDATEREGISTRY = 0x00000001;
    public const int  CDS_NORESET      = 0x10000000;
    public const int  DISP_CHANGE_SUCCESSFUL = 0;

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern int ChangeDisplaySettingsEx(string lpszDeviceName, ref DEVMODE lpDevMode, IntPtr hwnd, uint dwflags, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern int ChangeDisplaySettingsEx(string lpszDeviceName, IntPtr lpDevMode, IntPtr hwnd, uint dwflags, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern bool EnumDisplaySettings(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode);
}
"@ -ErrorAction Stop

# ─────────────────────────────────────────────────────────────
#  BANNER
# ─────────────────────────────────────────────────────────────
function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "        /\        " -NoNewline -ForegroundColor Cyan
    Write-Host "        _                   " -ForegroundColor White
    Write-Host "       /  \       " -NoNewline -ForegroundColor Cyan
    Write-Host "   __ (_) _ __  __ _  _ __  _   _  " -ForegroundColor White
    Write-Host "      ||        " -NoNewline -ForegroundColor Cyan
    Write-Host "  / _`` || || '__|/ _`` || '_ \| | | | " -ForegroundColor White
    Write-Host "   |    |       " -NoNewline -ForegroundColor Cyan
    Write-Host " | (_| || || |  | (_| || |_) | |_| | " -ForegroundColor White
    Write-Host "   | () |       " -NoNewline -ForegroundColor Cyan
    Write-Host "  \__,_||_||_|   \__, || .__/ \__,_| " -ForegroundColor White
    Write-Host "   |    |        " -NoNewline -ForegroundColor Cyan
    Write-Host "                 |___/ |_|            " -ForegroundColor White
    Write-Host "  /|    |\      " -ForegroundColor Cyan
    Write-Host " / |    | \     " -NoNewline -ForegroundColor Cyan
    Write-Host "   D I S P L A Y   M A N A G E R     " -ForegroundColor DarkCyan
    Write-Host "   \  /\  /     " -NoNewline -ForegroundColor Cyan
    Write-Host "   NVIDIA  *  Amazon EC2  *  Windows 11" -ForegroundColor DarkGray
    Write-Host "    \/  \/      " -ForegroundColor Cyan
    Write-Host "    |    |      " -ForegroundColor DarkCyan
    Write-Host "   /      \     " -ForegroundColor DarkCyan
    Write-Host "  / ' '' ' \    " -ForegroundColor DarkCyan
    Write-Host ""
}

# ─────────────────────────────────────────────────────────────
#  ENUMERATE DISPLAYS
# ─────────────────────────────────────────────────────────────
function Get-Displays {
    $displays = @()
    $idx      = 0

    while ($true) {
        $dev = New-Object DisplayAPI+DISPLAY_DEVICE
        $dev.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($dev)

        if (-not [DisplayAPI]::EnumDisplayDevices($null, $idx, [ref]$dev, 0)) { break }

        # Only include active/attached displays
        if ($dev.StateFlags -band [DisplayAPI]::DISPLAY_DEVICE_ACTIVE) {

            $isPrimary = [bool]($dev.StateFlags -band [DisplayAPI]::DISPLAY_DEVICE_PRIMARY_DEVICE)

            # Get current resolution via EnumDisplaySettings
            $dm = New-Object DisplayAPI+DEVMODE
            $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
            [DisplayAPI]::EnumDisplaySettings($dev.DeviceName, -1, [ref]$dm) | Out-Null

            # Friendly name via QueryDisplayConfig
            $friendlyName = Get-DisplayFriendlyName -DeviceName $dev.DeviceName

            $displays += [PSCustomObject]@{
                Index        = $displays.Count
                DeviceName   = $dev.DeviceName
                AdapterName  = $dev.DeviceString
                FriendlyName = $friendlyName
                Width        = $dm.dmPelsWidth
                Height       = $dm.dmPelsHeight
                RefreshRate  = $dm.dmDisplayFrequency
                PositionX    = $dm.dmPositionX
                PositionY    = $dm.dmPositionY
                IsPrimary    = $isPrimary
            }
        }
        $idx++
    }
    return $displays
}

function Get-DisplayFriendlyName {
    param([string]$DeviceName)

    try {
        $numPaths = 0u; $numModes = 0u
        [DisplayAPI]::GetDisplayConfigBufferSizes(0x4, [ref]$numPaths, [ref]$numModes) | Out-Null

        $paths = New-Object DisplayAPI+DISPLAYCONFIG_PATH_INFO[] $numPaths
        $modes = New-Object DisplayAPI+DISPLAYCONFIG_MODE_INFO[] $numModes

        [DisplayAPI]::QueryDisplayConfig(0x4, [ref]$numPaths, $paths, [ref]$numModes, $modes, [IntPtr]::Zero) | Out-Null

        foreach ($path in $paths) {
            $nameReq = New-Object DisplayAPI+DISPLAYCONFIG_TARGET_DEVICE_NAME
            $nameReq.header.type        = [DisplayAPI]::DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME
            $nameReq.header.size        = [System.Runtime.InteropServices.Marshal]::SizeOf($nameReq)
            $nameReq.header.adapterId   = $path.targetInfo.adapterId
            $nameReq.header.id          = $path.targetInfo.id

            if ([DisplayAPI]::DisplayConfigGetDeviceInfo([ref]$nameReq) -eq 0) {
                $friendly = $nameReq.monitorFriendlyDeviceName.Trim()
                if ($friendly -and $nameReq.monitorDevicePath -like "*$($DeviceName.Replace('\','\\'))*") {
                    return $friendly
                }
                if ($friendly -and $friendly -ne "") {
                    # Return first valid name found if path matching uncertain
                    return $friendly
                }
            }
        }
    } catch { }

    return ""
}

# ─────────────────────────────────────────────────────────────
#  DISPLAY TABLE
# ─────────────────────────────────────────────────────────────
function Show-Displays {
    param($Displays)

    Write-Host "  Detected displays:" -ForegroundColor White
    Write-Host ""
    Write-Host ("  {0,-4} {1,-22} {2,-28} {3,-14} {4,-10} {5}" -f `
        "No.", "Device", "Name", "Resolution", "Position", "Status") -ForegroundColor DarkGray
    Write-Host ("  {0}" -f ("-" * 90)) -ForegroundColor DarkGray

    foreach ($d in $Displays) {
        $res    = "$($d.Width)x$($d.Height)@$($d.RefreshRate)Hz"
        $pos    = "($($d.PositionX), $($d.PositionY))"
        $name   = if ($d.FriendlyName) { $d.FriendlyName } elseif ($d.AdapterName) { $d.AdapterName } else { "Unknown" }
        $status = if ($d.IsPrimary) { "[PRIMARY]" } else { "" }

        $color  = if ($d.IsPrimary) { "Green" } else { "White" }

        Write-Host ("  {0,-4} {1,-22} {2,-28} {3,-14} {4,-10} {5}" -f `
            "[$($d.Index+1)]", $d.DeviceName, $name, $res, $pos, $status) -ForegroundColor $color
    }

    Write-Host ""
}

# ─────────────────────────────────────────────────────────────
#  SET PRIMARY DISPLAY
# ─────────────────────────────────────────────────────────────
function Set-PrimaryDisplay {
    param([PSCustomObject]$Target, [PSCustomObject[]]$AllDisplays)

    if ($Target.IsPrimary) {
        Write-Host ""
        Write-Host "  '$($Target.DeviceName)' is already the primary display." -ForegroundColor Yellow
        Write-Log "Set-Primary: '$($Target.DeviceName)' is already primary."
        return
    }

    Write-Host ""
    Write-Host "  Setting primary display to: $($Target.DeviceName)" -ForegroundColor Yellow
    if ($Target.FriendlyName) {
        Write-Host "  ($($Target.FriendlyName)  $($Target.Width)x$($Target.Height))" -ForegroundColor DarkGray
    }
    Write-Host ""

    # Strategy:
    # 1. Shift all displays so that the target's current position becomes (0,0)
    # 2. Apply CDS_SET_PRIMARY | CDS_UPDATEREGISTRY | CDS_NORESET to the target
    # 3. Apply CDS_UPDATEREGISTRY | CDS_NORESET to all other displays (shifted)
    # 4. Commit with a final ChangeDisplaySettingsEx(null, null, 0)

    $offsetX = $Target.PositionX
    $offsetY = $Target.PositionY

    $errors = 0

    foreach ($d in $AllDisplays) {
        $dm = New-Object DisplayAPI+DEVMODE
        $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
        [DisplayAPI]::EnumDisplaySettings($d.DeviceName, -1, [ref]$dm) | Out-Null

        $dm.dmPositionX = $d.PositionX - $offsetX
        $dm.dmPositionY = $d.PositionY - $offsetY
        $dm.dmFields    = 0x00200000  # DM_POSITION

        $flags = [uint32]([DisplayAPI]::CDS_UPDATEREGISTRY -bor [DisplayAPI]::CDS_NORESET)
        if ($d.DeviceName -eq $Target.DeviceName) {
            $flags = $flags -bor [uint32][DisplayAPI]::CDS_SET_PRIMARY
        }

        $result = [DisplayAPI]::ChangeDisplaySettingsEx($d.DeviceName, [ref]$dm, [IntPtr]::Zero, $flags, [IntPtr]::Zero)

        if ($result -ne [DisplayAPI]::DISP_CHANGE_SUCCESSFUL) {
            Write-Host "  Warning: ChangeDisplaySettingsEx returned $result for $($d.DeviceName)" -ForegroundColor Yellow
            Write-Log "Set-Primary: ChangeDisplaySettingsEx returned $result for $($d.DeviceName)" -Level "WARN"
            $errors++
        }
    }

    # Commit all changes
    [DisplayAPI]::ChangeDisplaySettingsEx($null, [IntPtr]::Zero, [IntPtr]::Zero, 0, [IntPtr]::Zero) | Out-Null

    if ($errors -eq 0) {
        Write-Host "  Primary display set successfully." -ForegroundColor Green
        Write-Log "Primary display set to: $($Target.DeviceName) ($($Target.FriendlyName))" -Level "OK"
    } else {
        Write-Host "  Completed with $errors warning(s). The display may still have been updated." -ForegroundColor Yellow
        Write-Log "Set-Primary completed with $errors warnings for $($Target.DeviceName)." -Level "WARN"
    }
}

# ─────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────
Show-Banner

while ($true) {
    # Enumerate on every loop iteration so the list is always current
    $displays = Get-Displays

    if ($displays.Count -eq 0) {
        Write-Host "  No active displays found." -ForegroundColor Red
        Write-Host ""
        break
    }

    Show-Displays $displays

    if ($displays.Count -eq 1) {
        Write-Host "  Only one display detected -- nothing to change." -ForegroundColor DarkGray
        Write-Host ""
        break
    }

    # Build menu options
    $opts = $displays | ForEach-Object {
        $name   = if ($_.FriendlyName) { $_.FriendlyName } elseif ($_.AdapterName) { $_.AdapterName } else { "Unknown" }
        $marker = if ($_.IsPrimary) { " [current primary]" } else { "" }
        "$($_.DeviceName)  |  $name  |  $($_.Width)x$($_.Height)$marker"
    }

    Write-Host "  Select the display to set as primary:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $opts.Count; $i++) {
        Write-Host "    [$($i+1)] $($opts[$i])"
    }
    Write-Host "    [0] Exit"
    Write-Host ""

    do {
        Write-Host "  Selection: " -ForegroundColor Yellow -NoNewline
        $sel = Read-Host
        $num = -1
        [int]::TryParse($sel, [ref]$num) | Out-Null
    } while ($num -lt 0 -or $num -gt $displays.Count)

    if ($num -eq 0) {
        Write-Host "  Exiting." -ForegroundColor DarkGray
        Write-Host ""
        break
    }

    $chosen = $displays[$num - 1]
    Set-PrimaryDisplay -Target $chosen -AllDisplays $displays

    Write-Host ""
    Write-Host "  Press Enter to refresh display list or Ctrl+C to exit..." -ForegroundColor DarkGray
    Read-Host | Out-Null
    Clear-Host
    Show-Banner
}
