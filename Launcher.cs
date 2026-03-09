using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;

// Launcher: downloads airgpu-driver-manager-app.exe from GitHub and runs it.
// The app exe is the real driver manager — always fetched fresh so it stays updated.

[assembly: System.Reflection.AssemblyTitle("airgpu Driver Manager")]
[assembly: System.Reflection.AssemblyVersion("1.0.0.0")]

class Launcher
{
    const string AppUrl   = "https://github.com/Phat-shot/scripts/releases/latest/download/airgpu-driver-manager-app.exe";
    const string WorkDir  = @"C:\Program Files\airgpu\Driver Manager";
    const string AppExe   = @"C:\Program Files\airgpu\Driver Manager\airgpu-driver-manager-app.exe";
    const string StateFile= @"C:\Program Files\airgpu\Driver Manager\state.json";

    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, uint m);
    const int STD_INPUT = -10;
    const uint QUICK_EDIT = 0x0040, EXTENDED = 0x0080;

    [STAThread]
    static int Main(string[] args)
    {
        // Disable Quick Edit so clicking the console doesn't pause it
        IntPtr hIn = GetStdHandle(STD_INPUT);
        if (GetConsoleMode(hIn, out uint mode))
            SetConsoleMode(hIn, (mode & ~QUICK_EDIT) | EXTENDED);

        Console.OutputEncoding = System.Text.Encoding.UTF8;
        Console.Title = "airgpu Driver Manager";

        bool hasState = File.Exists(StateFile);
        bool hasApp   = File.Exists(AppExe);

        // On resume after reboot: state exists and app already cached — skip download
        if (hasState && hasApp)
        {
            Console.WriteLine("  Resuming...");
            return RunApp(args);
        }

        // Download fresh app exe
        Console.WriteLine("  Loading...");
        if (!Directory.Exists(WorkDir))
            try { Directory.CreateDirectory(WorkDir); } catch {}

        string tmp = AppExe + ".tmp";
        try
        {
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
            var wc = new WebClient();
            wc.Headers["User-Agent"] = "airgpu-launcher/1.0";
            wc.DownloadFile(AppUrl, tmp);

            // Atomic replace
            if (File.Exists(AppExe)) File.Delete(AppExe);
            File.Move(tmp, AppExe);
        }
        catch (Exception ex)
        {
            if (File.Exists(tmp)) try { File.Delete(tmp); } catch {}

            // Fallback: use cached exe if available
            if (File.Exists(AppExe))
            {
                Console.WriteLine("  [!] Update check failed — using cached version.");
                Console.WriteLine($"      {ex.Message}");
                System.Threading.Thread.Sleep(1500);
                return RunApp(args);
            }

            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine($"\n  Failed to download driver manager:\n  {ex.Message}");
            Console.ResetColor();
            Console.WriteLine("\n  Press any key to exit...");
            Console.ReadKey(true);
            return 1;
        }

        return RunApp(args);
    }

    static int RunApp(string[] args)
    {
        try
        {
            var psi = new ProcessStartInfo(AppExe)
            {
                UseShellExecute        = false,
                RedirectStandardError  = true,
                CreateNoWindow         = false,
                WorkingDirectory       = WorkDir
            };
            foreach (string a in args) psi.ArgumentList.Add(a);

            var p = Process.Start(psi);
            string stderr = p.StandardError.ReadToEnd();
            p.WaitForExit();

            if (p.ExitCode != 0 && !string.IsNullOrWhiteSpace(stderr))
            {
                Console.ForegroundColor = ConsoleColor.Red;
                Console.WriteLine($"\n  airgpu crashed (exit {p.ExitCode}):\n");
                Console.WriteLine("  " + stderr.Replace("\n","\n  "));
                Console.ResetColor();
                Console.WriteLine("\n  Press any key to exit...");
                Console.ReadKey(true);
            }
            return p.ExitCode;
        }
        catch (Exception ex)
        {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine($"\n  Failed to start driver manager:\n  {ex.Message}");
            Console.ResetColor();
            Console.WriteLine("\n  Press any key to exit...");
            Console.ReadKey(true);
            return 1;
        }
    }
}
