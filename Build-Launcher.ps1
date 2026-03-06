#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Compiles airgpu-driver-manager.exe -- self-contained launcher.
    Downloads Manage-NvidiaDriver.ps1 from GitHub and runs it directly.
    No separate PS1 launcher needed.
#>

$OutDir   = "C:\Program Files\airgpu"
$OutExe   = "$OutDir\airgpu-driver-manager.exe"
$IconPath = "$OutDir\airgpu.ico"

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

class Program {
    const string RawUrl  = "https://raw.githubusercontent.com/Phat-shot/scripts/main/Manage-NvidiaDriver.ps1";
    const string WorkDir = @"C:\Program Files\airgpu\Driver Manager";
    const string ScriptName = "Manage-NvidiaDriver.ps1";

    static int Main(string[] args) {
        string scriptPath = Path.Combine(WorkDir, ScriptName);

        // Ensure working directory exists
        if (!Directory.Exists(WorkDir))
            Directory.CreateDirectory(WorkDir);

        // Banner
        Console.Clear();
        Console.ForegroundColor = ConsoleColor.White;
        Console.WriteLine("");
        Console.WriteLine("     ___________       _                   ");
        Console.WriteLine("    |           |   __ (_) _ __  __ _  _ __ ");
        Console.WriteLine("    |  _______  |  / _` || || '__|/ _` || '_ \\");
        Console.WriteLine("    | |       | | | (_| || || |  | (_| || |_) |");
        Console.WriteLine("    | |_______| |  \\__,_||_||_|   \\__, || .__/");
        Console.WriteLine("    |___________|                  |___/ |_|  ");
        Console.WriteLine("");
        Console.ForegroundColor = ConsoleColor.DarkCyan;
        Console.WriteLine("                  D R I V E R   M A N A G E R");
        Console.ForegroundColor = ConsoleColor.DarkGray;
        Console.WriteLine("                  NVIDIA  *  Amazon EC2  *  Windows 11");
        Console.ResetColor();
        Console.WriteLine("");

        // Download latest script
        Console.ForegroundColor = ConsoleColor.Yellow;
        Console.WriteLine("  Fetching latest script from GitHub...");
        Console.ForegroundColor = ConsoleColor.DarkGray;
        Console.WriteLine("  " + RawUrl);
        Console.ResetColor();
        Console.WriteLine("");

        try {
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
            using (var wc = new WebClient())
                wc.DownloadFile(RawUrl, scriptPath);
            Console.ForegroundColor = ConsoleColor.Green;
            Console.WriteLine("  Downloaded: " + scriptPath);
            Console.ResetColor();
        } catch (Exception ex) {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine("  ERROR: Could not download script.");
            Console.WriteLine("  " + ex.Message);
            Console.ResetColor();
            Console.WriteLine("\n  Press any key to exit...");
            Console.ReadKey();
            return 1;
        }

        // Launch
        Console.WriteLine("");
        Console.ForegroundColor = ConsoleColor.Cyan;
        Console.WriteLine("  Launching Driver Manager...");
        Console.ResetColor();
        Console.WriteLine("");

        string passArgs = args.Length > 0 ? string.Join(" ", args) : "";
        string psArgs   = string.Format(
            "-NoProfile -ExecutionPolicy Bypass -File \"{0}\" {1}",
            scriptPath, passArgs).Trim();

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName        = "powershell.exe";
        psi.Arguments       = psArgs;
        psi.UseShellExecute = false;

        Process proc = Process.Start(psi);
        proc.WaitForExit();
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
