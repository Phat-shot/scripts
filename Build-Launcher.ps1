#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Compiles airgpu-driver-manager.exe using C# via Add-Type.
    No Visual Studio or additional tools required -- uses .NET built into Windows.
    
.NOTES
    Run once to build the EXE. Place airgpu.ico in the same folder first.
    Output: C:\Program Files\airgpu\airgpu-driver-manager.exe
#>

$OutDir    = "C:\Program Files\airgpu"
$OutExe    = "$OutDir\airgpu-driver-manager.exe"
$IconPath  = "$OutDir\airgpu.ico"
$Launcher  = "$OutDir\Driver Manager\Launch-NvidiaDriverManager.ps1"

# ── Embedded application manifest (requests elevation) ───────
$manifest = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity version="1.0.0.0" processorArchitecture="X86"
      name="airgpu.DriverManager" type="win32"/>
  <description>airgpu Driver Manager</description>
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
"@

# ── C# source ─────────────────────────────────────────────────
$source = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.ComponentModel;

class Program {
    static int Main(string[] args) {
        string exeDir  = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string ps1Path = Path.Combine(exeDir, "Driver Manager", "Launch-NvidiaDriverManager.ps1");

        if (!File.Exists(ps1Path)) {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine("  ERROR: Launcher script not found:");
            Console.WriteLine("  " + ps1Path);
            Console.ResetColor();
            Console.WriteLine("\n  Press any key to exit...");
            Console.ReadKey();
            return 1;
        }

        // Build argument string -- pass through any args (e.g. -Resume)
        string passArgs = args.Length > 0 ? string.Join(" ", args) : "";
        string psArgs   = string.Format(
            "-NoProfile -ExecutionPolicy Bypass -File \"{0}\" {1}",
            ps1Path, passArgs).Trim();

        var psi = new ProcessStartInfo {
            FileName               = "powershell.exe",
            Arguments              = psArgs,
            UseShellExecute        = false,   // keeps same console window
            CreateNoWindow         = false
        };

        var proc = Process.Start(psi);
        proc.WaitForExit();
        return proc.ExitCode;
    }
}
"@

# ── Compile ───────────────────────────────────────────────────
Write-Host "  Compiling airgpu-driver-manager.exe..." -ForegroundColor Cyan

$tempManifest = [System.IO.Path]::GetTempFileName() + ".manifest"
$manifest | Set-Content $tempManifest -Encoding UTF8

$compilerParams = New-Object System.CodeDom.Compiler.CompilerParameters
$compilerParams.GenerateExecutable      = $true
$compilerParams.OutputAssembly          = $OutExe
$compilerParams.CompilerOptions         = "/target:exe /platform:x64 /win32manifest:`"$tempManifest`""
$compilerParams.ReferencedAssemblies.Add("System.dll") | Out-Null

if (Test-Path $IconPath) {
    $compilerParams.CompilerOptions    += " /win32icon:`"$IconPath`""
    Write-Host "  Icon: $IconPath" -ForegroundColor DarkGray
} else {
    Write-Host "  [WARN] Icon not found at $IconPath -- building without icon" -ForegroundColor Yellow
}

$provider = New-Object Microsoft.CSharp.CSharpCodeProvider
$result   = $provider.CompileAssemblyFromSource($compilerParams, $source)

Remove-Item $tempManifest -Force -ErrorAction SilentlyContinue

if ($result.Errors.Count -gt 0) {
    Write-Host "  Compilation failed:" -ForegroundColor Red
    $result.Errors | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    exit 1
}

Write-Host "  Done: $OutExe" -ForegroundColor Green
Write-Host ""
Write-Host "  The EXE will:" -ForegroundColor DarkGray
Write-Host "    - Request elevation via UAC (requireAdministrator manifest)" -ForegroundColor DarkGray
Write-Host "    - Run Launch-NvidiaDriverManager.ps1 in the same console window" -ForegroundColor DarkGray
Write-Host "    - Pass through arguments (e.g. -Resume)" -ForegroundColor DarkGray
