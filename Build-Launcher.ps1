<#
.SYNOPSIS
    Compiles airgpu-driver-manager.exe -- self-contained launcher.
    Intended to run in CI (GitHub Actions) or locally.
    Icon is looked up relative to this script's directory.
#>
param(
    [string]$OutDir   = "$PSScriptRoot\build",
    [string]$IconPath = "$PSScriptRoot\airgpu.ico"
)

$OutExe = "$OutDir\airgpu-driver-manager.exe"

# Find csc.exe
$csc = Get-ChildItem "C:\Windows\Microsoft.NET\Framework64" -Filter "csc.exe" -Recurse -ErrorAction SilentlyContinue |
       Sort-Object FullName -Descending | Select-Object -First 1
if (-not $csc) { Write-Host "  ERROR: csc.exe not found." -ForegroundColor Red; exit 1 }
Write-Host "  Using: $($csc.FullName)" -ForegroundColor DarkGray

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# Write manifest
$tempManifest = "$env:TEMP\airgpu.manifest"
@'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity version="1.0.0.0" processorArchitecture="X86"
      name="airgpu.DriverManager" type="win32"/>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    </application>
  </compatibility>
</assembly>
'@ | Set-Content $tempManifest -Encoding UTF8

# Write C# source
$tempCs = "$env:TEMP\airgpu_launcher.cs"
@'
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;

class Program {
    // Disable Quick Edit Mode so clicking the console window does not pause the process
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
    const int STD_INPUT_HANDLE    = -10;
    const uint ENABLE_QUICK_EDIT   = 0x0040;
    const uint ENABLE_EXTENDED_FLAGS = 0x0080;

    static void DisableQuickEdit() {
        IntPtr handle = GetStdHandle(STD_INPUT_HANDLE);
        uint mode;
        if (GetConsoleMode(handle, out mode)) {
            mode &= ~ENABLE_QUICK_EDIT;   // clear Quick Edit
            mode |= ENABLE_EXTENDED_FLAGS; // required for the above to take effect
            SetConsoleMode(handle, mode);
        }
    }
    const string BaseUrl    = "https://artifacts.airgpu.com/driver-updater/";
    const string WorkDir    = @"C:\Program Files\airgpu\Driver Manager";
    const string ScriptName = "Manage-NvidiaDriver.ps1";

    static int Main(string[] args) {
        DisableQuickEdit();
        string scriptPath = Path.Combine(WorkDir, ScriptName);

        // Ensure working directory exists
        if (!Directory.Exists(WorkDir))
            Directory.CreateDirectory(WorkDir);

        // Banner
        Console.Clear();

        // Skip download if state file exists (mid-install resume)
        string stateFile = Path.Combine(WorkDir, "state.json");
        bool hasState    = File.Exists(stateFile) && File.Exists(scriptPath);

        // Parse --version argument (alphanumeric, dots, dashes)
        string version = null;
        for (int i = 0; i < args.Length - 1; i++) {
            if (args[i] == "--version" || args[i] == "-version") {
                string v = args[i + 1];
                bool valid = v.Length > 0;
                foreach (char ch in v)
                    if (!char.IsLetterOrDigit(ch) && ch != '.' && ch != '-')
                        valid = false;
                if (valid) version = v;
            }
        }
        string channel = version != null ? version : "latest";
        string rawUrl  = BaseUrl + channel + "/" + ScriptName;

        if (!hasState) {
            Console.ForegroundColor = ConsoleColor.DarkGray;
            Console.Write("  Loading...");
            Console.ResetColor();
            try {
                ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
                using (var wc = new WebClient()) {
                    wc.Headers["User-Agent"] = "airgpu-launcher/1.0";
                    wc.DownloadFile(rawUrl, scriptPath);
                }
                Console.Write("\r           \r");
            } catch (Exception ex) {
                Console.WriteLine();
                if (!File.Exists(scriptPath)) {
                    Console.ForegroundColor = ConsoleColor.Red;
                    Console.WriteLine("  ERROR: Script not found and download failed.");
                    Console.WriteLine("  " + ex.Message);
                    Console.ResetColor();
                    Console.WriteLine("\n  Press any key to exit...");
                    Console.ReadKey();
                    return 1;
                }
                Console.ForegroundColor = ConsoleColor.Yellow;
                Console.WriteLine("  Download failed -- using cached script.");
                Console.ResetColor();
            }
        }

        string passArgs = args.Length > 0 ? string.Join(" ", args) : "";
        string psArgs   = string.Format(
            "-NoProfile -ExecutionPolicy Bypass -File \"{0}\" {1}",
            scriptPath, passArgs).Trim();

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName               = "powershell.exe";
        psi.Arguments              = psArgs;
        psi.UseShellExecute        = false;
        psi.RedirectStandardError  = true;

        Process proc = Process.Start(psi);
        proc.WaitForExit();
        if (proc.ExitCode != 0) {
            string err = proc.StandardError.ReadToEnd().Trim();
            if (err.Length > 0) {
                Console.ForegroundColor = ConsoleColor.Red;
                Console.WriteLine("\n  PowerShell error:");
                Console.WriteLine(err.Length > 800 ? err.Substring(0, 800) : err);
                Console.ResetColor();
                Console.WriteLine("\n  Press any key to exit...");
                Console.ReadKey();
            }
        }
        return proc.ExitCode;
    }
}
'@ | Set-Content $tempCs -Encoding UTF8

# Compile
$iconArg  = if (Test-Path $IconPath) { "/win32icon:`"$IconPath`"" } else { "" }
$cscArgs  = @(
    "/target:exe", "/platform:x64",
    "/out:`"$OutExe`"",
    "/win32manifest:`"$tempManifest`""
)
if ($iconArg) { $cscArgs += $iconArg }
$cscArgs += "`"$tempCs`""

Write-Host "  Compiling..." -ForegroundColor Cyan
$result = & $csc.FullName $cscArgs 2>&1

Remove-Item $tempManifest, $tempCs -Force -ErrorAction SilentlyContinue

if ($LASTEXITCODE -ne 0) {
    Write-Host "  Compilation failed:" -ForegroundColor Red
    $result | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    exit 1
}

Write-Host "  Done: $OutExe" -ForegroundColor Green
