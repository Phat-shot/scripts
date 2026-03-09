using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Threading;

[assembly: AssemblyTitle("airgpu Driver Manager")]
[assembly: AssemblyVersion("2.0.0.0")]

namespace AirgpuDriverManager
{
    class EntryPoint
    {
        [STAThread]
        static void Main(string[] args)
        {
            var app = new App();
            app.Run(new MainWindow());
        }
    }

    class App : Application
    {
        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);
            DispatcherUnhandledException += (s, ex) => {
                MessageBox.Show(ex.Exception.ToString(), "airgpu — Unhandled Error",
                    MessageBoxButton.OK, MessageBoxImage.Error);
                ex.Handled = true;
            };
        }
    }

    // ── DATA MODELS ──────────────────────────────────────────────────────────
    class DriverInfo
    {
        public bool   Installed { get; set; }
        public string GpuName   { get; set; } = "";
        public string Version   { get; set; } = "";
        public string Variant   { get; set; } = "GRID";
    }

    class S3Info
    {
        public string Version  { get; set; } = "Unknown";
        public string S3Key    { get; set; } = "";
        public string S3Bucket { get; set; } = "";
        public bool   Error    { get; set; }
    }

    // ── COLOURS + THEME ──────────────────────────────────────────────────────
    static class Theme
    {
        public static readonly Color Bg       = C(0x09, 0x09, 0x0f);
        public static readonly Color Surface  = C(0x0e, 0x0f, 0x17);
        public static readonly Color Surface2 = C(0x13, 0x14, 0x1f);
        public static readonly Color Border   = C(0x1e, 0x21, 0x33);
        public static readonly Color Border2  = C(0x25, 0x28, 0x40);
        public static readonly Color Accent   = C(0x20, 0x9c, 0xee);
        public static readonly Color Green    = C(0x00, 0xc9, 0x8d);
        public static readonly Color Yellow   = C(0xe8, 0xa0, 0x20);
        public static readonly Color Red      = C(0xe0, 0x44, 0x44);
        public static readonly Color Purple   = C(0xb0, 0x60, 0xe0);
        public static readonly Color TextPri  = C(0xd8, 0xdc, 0xe8);
        public static readonly Color TextSec  = C(0x5a, 0x62, 0x78);
        public static readonly Color TextDim  = C(0x3a, 0x40, 0x55);
        static Color C(byte r, byte g, byte b) => Color.FromRgb(r, g, b);
        public static SolidColorBrush Brush(Color c) => new SolidColorBrush(c);
        public static SolidColorBrush BrushA(Color c, byte a) => new SolidColorBrush(Color.FromArgb(a, c.R, c.G, c.B));
    }

    // ── MAIN WINDOW ──────────────────────────────────────────────────────────
    class MainWindow : Window
    {
        const string WorkDir     = @"C:\Program Files\airgpu\Driver Manager";
        const string DownloadDir = @"C:\Program Files\airgpu\Driver Manager\Downloads";
        const string LogFile     = @"C:\Program Files\airgpu\Driver Manager\driver_manager.log";
        const string StateFile   = @"C:\Program Files\airgpu\Driver Manager\state.json";
        const string CredsFile   = @"C:\Users\user\.aws\credentials";

        // UI refs
        Ellipse     _statusDot;
        TextBlock   _statusLabel, _statusDetail;
        TextBlock   _gpuName, _variantBadge, _driverVersion;
        Border      _updateBadge;
        TextBlock   _updateBadgeText;
        StackPanel  _actionPanel;
        Border      _progressSection;
        TextBlock   _progressFilename, _progressPct;
        Rectangle   _progressFill;
        DispatcherTimer _spinTimer;
        double      _spinAngle;

        // State
        DriverInfo _current;
        S3Info     _latestGaming, _latestGrid;
        bool       _busy;

        public MainWindow()
        {
            Title  = "airgpu Driver Manager";
            Width  = 420; Height = 580;
            MinWidth = 420; MinHeight = 580;
            ResizeMode   = ResizeMode.CanMinimize;
            WindowStyle  = WindowStyle.None;
            AllowsTransparency = false;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Background   = Theme.Brush(Theme.Bg);
            FontFamily   = new FontFamily("Consolas");

            BuildUI();
            Loaded += async (s, e) => await InitAsync();
        }

        // ═════════════════════════════════════════════════════════════════════
        //  UI CONSTRUCTION
        // ═════════════════════════════════════════════════════════════════════
        void BuildUI()
        {
            var root = new Grid();
            root.RowDefinitions.Add(Row(40));        // 0 titlebar
            root.RowDefinitions.Add(Row(1));         // 1 divider
            root.RowDefinitions.Add(Row(64));        // 2 status bar
            root.RowDefinitions.Add(Row(1));         // 3 divider
            root.RowDefinitions.Add(Row(double.NaN)); // 4 progress (auto)
            root.RowDefinitions.Add(Row(110));       // 5 gpu card
            root.RowDefinitions.Add(Row(1, star: true)); // 6 actions (stretch)
            root.RowDefinitions.Add(Row(32));        // 7 footer

            // ── 0: Titlebar ──────────────────────────────────────────────────
            var tb = MkBorder(Theme.Bg, pad: new Thickness(0));
            var tg = new Grid();
            var tLeft = new StackPanel {
                Orientation = Orientation.Horizontal,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(16,0,0,0) };
            var tDot = new Ellipse { Width=7,Height=7, Fill=Theme.Brush(Theme.Accent), Margin=new Thickness(0,0,9,0) };
            AnimatePulse(tDot);
            var tLogo = Txt("AIRGPU ", 11, Theme.TextPri, bold:true);
            var tSub  = Txt("DRIVER MANAGER", 11, Theme.Accent);
            tLeft.Children.Add(tDot); tLeft.Children.Add(tLogo); tLeft.Children.Add(tSub);
            var tClose = new Button {
                Content = "✕", Width=40, Height=40,
                Background=Brushes.Transparent, BorderThickness=new Thickness(0),
                Foreground=Theme.Brush(Theme.TextDim), FontFamily=new FontFamily("Consolas"),
                FontSize=12, HorizontalAlignment=HorizontalAlignment.Right,
                VerticalAlignment=VerticalAlignment.Center, Cursor=Cursors.Hand };
            tClose.Click      += (_,__) => Application.Current.Shutdown();
            tClose.MouseEnter += (_,__) => tClose.Foreground = Theme.Brush(Theme.Red);
            tClose.MouseLeave += (_,__) => tClose.Foreground = Theme.Brush(Theme.TextDim);
            tg.Children.Add(tLeft); tg.Children.Add(tClose);
            tb.Child = tg;
            tb.MouseDown += (_,e) => { if(e.ChangedButton==MouseButton.Left) DragMove(); };
            SetRow(tb, 0, root);

            // ── 1,3,7-border: dividers ───────────────────────────────────────
            foreach (int r in new[]{1,3}) SetRow(MkBorder(Theme.Border, h:1), r, root);

            // ── 2: Status bar ────────────────────────────────────────────────
            var sb = MkBorder(Theme.Surface, pad: new Thickness(20,0,20,0));
            var sg = new Grid();
            sg.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            sg.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            // Animated ring
            var ringCanvas = new Canvas { Width=36, Height=36, VerticalAlignment=VerticalAlignment.Center };
            var ringEllipse = new Ellipse {
                Width=28, Height=28,
                Stroke=Theme.BrushA(Theme.Accent, 35),
                StrokeThickness=1.5 };
            Canvas.SetLeft(ringEllipse,4); Canvas.SetTop(ringEllipse,4);
            _statusDot = new Ellipse { Width=8,Height=8, Fill=Theme.Brush(Theme.Accent) };
            Canvas.SetLeft(_statusDot,14); Canvas.SetTop(_statusDot,14);
            ringCanvas.Children.Add(ringEllipse);
            ringCanvas.Children.Add(_statusDot);
            Grid.SetColumn(ringCanvas,0);
            sg.Children.Add(ringCanvas);

            var stexts = new StackPanel { Margin=new Thickness(14,0,0,0), VerticalAlignment=VerticalAlignment.Center };
            _statusLabel  = Txt("Initializing", 11, Theme.Accent, bold:true, tracking:.1);
            _statusDetail = Txt("Starting up...", 10, Theme.TextSec);
            _statusDetail.Margin = new Thickness(0,3,0,0);
            stexts.Children.Add(_statusLabel); stexts.Children.Add(_statusDetail);
            Grid.SetColumn(stexts,1); sg.Children.Add(stexts);
            sb.Child = sg;
            SetRow(sb, 2, root);

            // ── 4: Progress (hidden by default) ──────────────────────────────
            var psec = new Border {
                Background=Theme.Brush(Theme.Surface),
                BorderBrush=Theme.Brush(Theme.Border),
                BorderThickness=new Thickness(0,0,0,1),
                Padding=new Thickness(20,10,20,10),
                Visibility=Visibility.Collapsed };
            var pstack = new StackPanel();
            var phdr = new Grid();
            phdr.ColumnDefinitions.Add(new ColumnDefinition { Width=new GridLength(1,GridUnitType.Star) });
            phdr.ColumnDefinitions.Add(new ColumnDefinition { Width=GridLength.Auto });
            _progressFilename = Txt("", 9, Theme.TextSec, tracking:.04);
            _progressPct      = Txt("", 9, Theme.Accent);
            Grid.SetColumn(_progressPct,1);
            phdr.Children.Add(_progressFilename); phdr.Children.Add(_progressPct);
            var track = new Border { Height=2, Background=Theme.Brush(Theme.Border2), Margin=new Thickness(0,6,0,0) };
            var trackInner = new Grid();
            _progressFill = new Rectangle { Fill=Theme.Brush(Theme.Accent), HorizontalAlignment=HorizontalAlignment.Left, Width=0 };
            trackInner.Children.Add(_progressFill);
            track.Child = trackInner;
            pstack.Children.Add(phdr); pstack.Children.Add(track);
            psec.Child = pstack;
            _progressSection = psec;
            SetRow(psec, 4, root);

            // ── 5: GPU Card ──────────────────────────────────────────────────
            var card = new Border {
                Margin=new Thickness(16,14,16,0),
                Background=Theme.Brush(Theme.Bg),
                BorderBrush=Theme.Brush(Theme.Border2),
                BorderThickness=new Thickness(1),
                Padding=new Thickness(20,16,20,16) };
            var cg = new Grid();
            cg.RowDefinitions.Add(new RowDefinition());
            cg.RowDefinitions.Add(new RowDefinition { Height=new GridLength(8) });
            cg.RowDefinitions.Add(new RowDefinition());
            cg.ColumnDefinitions.Add(new ColumnDefinition { Width=new GridLength(1,GridUnitType.Star) });
            cg.ColumnDefinitions.Add(new ColumnDefinition { Width=GridLength.Auto });

            _gpuName = Txt("—", 20, Theme.TextPri, bold:true);
            _gpuName.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetRow(_gpuName,0); Grid.SetColumn(_gpuName,0); cg.Children.Add(_gpuName);

            var metaRow = new StackPanel { Orientation=Orientation.Horizontal };
            _variantBadge = new TextBlock {
                Text="—", FontSize=9, FontFamily=new FontFamily("Consolas"),
                FontWeight=FontWeights.SemiBold, LetterSpacing=1.5,
                Foreground=Theme.Brush(Theme.Accent),
                Background=Theme.BrushA(Theme.Accent,25),
                Padding=new Thickness(7,2,7,2),
                VerticalAlignment=VerticalAlignment.Center };
            _driverVersion = Txt("", 12, Theme.TextSec);
            _driverVersion.Margin = new Thickness(10,0,0,0);
            _driverVersion.VerticalAlignment = VerticalAlignment.Center;
            metaRow.Children.Add(_variantBadge); metaRow.Children.Add(_driverVersion);
            Grid.SetRow(metaRow,2); Grid.SetColumn(metaRow,0); cg.Children.Add(metaRow);

            _updateBadge = new Border {
                BorderThickness=new Thickness(1),
                Padding=new Thickness(7,3,7,3),
                VerticalAlignment=VerticalAlignment.Center,
                HorizontalAlignment=HorizontalAlignment.Right,
                Visibility=Visibility.Collapsed };
            _updateBadgeText = Txt("", 9, Theme.Yellow, tracking:.08);
            _updateBadge.Child = _updateBadgeText;
            Grid.SetRow(_updateBadge,0); Grid.SetColumn(_updateBadge,1);
            Grid.SetRowSpan(_updateBadge,3); cg.Children.Add(_updateBadge);

            card.Child = cg;
            SetRow(card, 5, root);

            // ── 6: Action panel ──────────────────────────────────────────────
            _actionPanel = new StackPanel {
                Margin=new Thickness(16,10,16,10),
                VerticalAlignment=VerticalAlignment.Top,
                Visibility=Visibility.Collapsed };
            var actionScroll = new ScrollViewer {
                VerticalScrollBarVisibility=ScrollBarVisibility.Hidden,
                Content=_actionPanel };
            SetRow(actionScroll, 6, root);

            // ── 7: Footer ────────────────────────────────────────────────────
            var foot = new Border { Background=Theme.Brush(Theme.Bg), Padding=new Thickness(20,0,20,0) };
            var footG = new Grid();
            footG.Children.Add(Txt("airgpu.com", 8, Theme.TextDim, tracking:.1));
            var fv = Txt("driver manager v2.0", 8, Theme.TextDim, tracking:.08);
            fv.HorizontalAlignment = HorizontalAlignment.Right;
            footG.Children.Add(fv);
            foot.Child = footG;
            SetRow(foot, 7, root);

            Content = root;
            StartSpinTimer();
        }

        // ═════════════════════════════════════════════════════════════════════
        //  ANIMATION
        // ═════════════════════════════════════════════════════════════════════
        void StartSpinTimer()
        {
            _spinTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(40) };
            _spinTimer.Tick += (_,__) => {
                _spinAngle += 0.07;
                double s = 1.0 + 0.28 * Math.Sin(_spinAngle);
                _statusDot.RenderTransform       = new ScaleTransform(s,s,4,4);
                _statusDot.RenderTransformOrigin = new Point(.5,.5);
            };
            _spinTimer.Start();
        }

        void AnimatePulse(Ellipse e)
        {
            var t = new DispatcherTimer { Interval=TimeSpan.FromMilliseconds(40) };
            double a = 0;
            t.Tick += (_,__) => {
                a += 0.06; double s = 1.0+0.3*Math.Sin(a);
                e.RenderTransform = new ScaleTransform(s,s); e.RenderTransformOrigin=new Point(.5,.5);
            };
            t.Start();
        }

        // ═════════════════════════════════════════════════════════════════════
        //  STATUS HELPERS
        // ═════════════════════════════════════════════════════════════════════
        void SetStatus(string label, string detail, Color dotColor)
        {
            Dispatcher.Invoke(() => {
                _statusLabel.Text       = label.ToUpperInvariant();
                _statusLabel.Foreground = Theme.Brush(dotColor);
                _statusDetail.Text      = detail;
                _statusDot.Fill         = Theme.Brush(dotColor);
            });
        }

        void SetProgress(string filename, double pct, long doneMb, long totalMb)
        {
            Dispatcher.Invoke(() => {
                _progressSection.Visibility = Visibility.Visible;
                _progressFilename.Text = filename;
                _progressPct.Text      = $"{(int)pct}%";
                // Width relative to track — use ActualWidth if available
                double trackW = Math.Max(1, _progressSection.ActualWidth - 40);
                _progressFill.Width = trackW * pct / 100.0;
            });
        }

        void HideProgress() => Dispatcher.Invoke(() => _progressSection.Visibility = Visibility.Collapsed);

        void ShowGpuCard(DriverInfo info)
        {
            Dispatcher.Invoke(() => {
                _gpuName.Text = info.GpuName;
                bool gaming   = info.Variant == "Gaming";
                _variantBadge.Text       = info.Variant.ToUpperInvariant();
                _variantBadge.Foreground = Theme.Brush(gaming ? Theme.Purple : Theme.Accent);
                _variantBadge.Background = Theme.BrushA(gaming ? Theme.Purple : Theme.Accent, 25);
                _driverVersion.Text      = info.Version;
            });
        }

        void ShowUpdateBadge(string text, Color color)
        {
            Dispatcher.Invoke(() => {
                _updateBadge.BorderBrush     = Theme.BrushA(color, 70);
                _updateBadge.Background      = Theme.BrushA(color, 15);
                _updateBadgeText.Text        = text;
                _updateBadgeText.Foreground  = Theme.Brush(color);
                _updateBadge.Visibility      = Visibility.Visible;
            });
        }

        // ═════════════════════════════════════════════════════════════════════
        //  INIT FLOW
        // ═════════════════════════════════════════════════════════════════════
        async Task InitAsync()
        {
            _busy = true;

            // Check resume state
            string state = ReadState();
            if (state != null && state.Contains("AFTER_UNINSTALL_AND_CLEANUP"))
            {
                await ResumeInstallAsync(state);
                return;
            }

            SetStatus("Loading", "Detecting GPU...", Theme.Accent);
            _current = await Task.Run(() => DetectDriver());

            if (!_current.Installed)
            {
                SetStatus("No Driver", "No NVIDIA driver detected.", Theme.Red);
                _busy = false;
                return;
            }

            ShowGpuCard(_current);
            SetStatus("Checking", "Fetching latest driver versions...", Theme.Accent);

            var tG = Task.Run(() => FetchS3Version("nvidia-gaming", "windows/latest/"));
            var tR = Task.Run(() => FetchS3Version("ec2-windows-nvidia-drivers", "latest/"));
            await Task.WhenAll(tG, tR);
            _latestGaming = tG.Result;
            _latestGrid   = tR.Result;

            Log($"GPU: {_current.GpuName} | {_current.Variant} {_current.Version} | Gaming: {_latestGaming.Version} | GRID: {_latestGrid.Version}");

            var latestSame = _current.Variant == "GRID" ? _latestGrid : _latestGaming;
            bool updateAvail = false;
            try {
                if (latestSame.Version != "Unknown")
                    updateAvail = new Version(latestSame.Version) > new Version(_current.Version);
            } catch {}

            if (updateAvail)
            {
                ShowUpdateBadge($"↑ {latestSame.Version}", Theme.Yellow);
                SetStatus("Update Available", $"{_current.Variant} {latestSame.Version} ready to install.", Theme.Yellow);
            }
            else if (latestSame.Error)
                SetStatus("Ready", "Update server unreachable — version check skipped.", Theme.TextSec);
            else
                SetStatus("Ready", "Driver up to date.", Theme.Green);

            BuildActionButtons(updateAvail, latestSame);
            Dispatcher.Invoke(() => _actionPanel.Visibility = Visibility.Visible);
            _busy = false;
        }

        // ═════════════════════════════════════════════════════════════════════
        //  ACTION BUTTONS
        // ═════════════════════════════════════════════════════════════════════
        void BuildActionButtons(bool updateAvail, S3Info latestSame)
        {
            Dispatcher.Invoke(() => {
                _actionPanel.Children.Clear();
                _actionPanel.Children.Add(ActionLabel("Actions"));

                if (updateAvail)
                    _actionPanel.Children.Add(ActionBtn(
                        "↑", $"Update to {_current.Variant} {latestSame.Version}",
                        $"Current: {_current.Version}",
                        Theme.Accent, () => BeginInstall(_current.Variant, latestSame)));

                bool gamingSupported = IsGamingSupported(_current.GpuName);
                if (_current.Variant == "GRID")
                {
                    _actionPanel.Children.Add(ActionBtn(
                        "⇄", "Switch to Gaming / GeForce",
                        gamingSupported
                            ? $"Install {_latestGaming.Version} Cloud Gaming driver"
                            : $"Not available for {_current.GpuName}",
                        Theme.Purple,
                        gamingSupported ? (Action)(() => BeginInstall("Gaming", _latestGaming)) : null,
                        disabled: !gamingSupported));
                }
                else
                {
                    _actionPanel.Children.Add(ActionBtn(
                        "⇄", "Switch to GRID / Enterprise",
                        $"Install {_latestGrid.Version} GRID driver",
                        Theme.Accent, () => BeginInstall("GRID", _latestGrid)));
                }

                _actionPanel.Children.Add(Spacer(6));
                _actionPanel.Children.Add(ActionBtn(
                    "✕", "Exit", null,
                    Theme.TextDim, () => Application.Current.Shutdown(), small: true));
            });
        }

        // ═════════════════════════════════════════════════════════════════════
        //  INSTALL FLOW
        // ═════════════════════════════════════════════════════════════════════
        async void BeginInstall(string variant, S3Info s3)
        {
            if (_busy) return;
            _busy = true;
            Dispatcher.Invoke(() => {
                _actionPanel.Visibility  = Visibility.Collapsed;
                _updateBadge.Visibility  = Visibility.Collapsed;
            });

            // Step 1: Download
            SetStatus("Downloading", $"{variant} {s3.Version}...", Theme.Accent);
            string installer = await Task.Run(() => DownloadDriver(s3));
            if (installer == null) {
                SetStatus("Error", "Download failed. Check log for details.", Theme.Red);
                Dispatcher.Invoke(() => {
                    _actionPanel.Children.Clear();
                    _actionPanel.Children.Add(ActionBtn("↩","Retry", null, Theme.Yellow, () => { _busy=false; _actionPanel.Visibility=Visibility.Visible; BuildActionButtons(false, s3); }));
                    _actionPanel.Children.Add(ActionBtn("✕","Exit", null, Theme.TextDim, () => Application.Current.Shutdown(), small:true));
                    _actionPanel.Visibility = Visibility.Visible;
                });
                _busy = false;
                return;
            }
            HideProgress();
            WriteState("AFTER_DOWNLOAD", variant, s3.Version, installer, s3.S3Bucket, s3.S3Key);

            // Step 2: Uninstall
            SetStatus("Uninstalling", "Removing current NVIDIA driver...", Theme.Yellow);
            await Task.Run(() => UninstallDriver());
            await Task.Run(() => RegistryCleanup());
            WriteState("AFTER_UNINSTALL_AND_CLEANUP", variant, s3.Version, installer, s3.S3Bucket, s3.S3Key);

            // Prompt reboot
            SetStatus("Reboot Required", "Driver removed — one reboot needed to install.", Theme.Yellow);
            Dispatcher.Invoke(() => {
                _actionPanel.Children.Clear();
                _actionPanel.Children.Add(ActionLabel("Next Step"));
                _actionPanel.Children.Add(ActionBtn("↻","Reboot Now",
                    "Install completes automatically after restart",
                    Theme.Yellow, () => {
                        RegisterResume();
                        Process.Start("shutdown", "/r /t 5 /c \"airgpu driver install\"");
                        Application.Current.Shutdown();
                    }));
                _actionPanel.Children.Add(Spacer(4));
                _actionPanel.Children.Add(ActionBtn("—","Reboot Later", null,
                    Theme.TextDim, () => Application.Current.Shutdown(), small:true));
                _actionPanel.Visibility = Visibility.Visible;
            });
            _busy = false;
        }

        async Task ResumeInstallAsync(string stateJson)
        {
            string installer = JsonGet(stateJson, "InstallerPath");
            string variant   = JsonGet(stateJson, "TargetVariant");
            string version   = JsonGet(stateJson, "TargetVersion");

            _current = new DriverInfo { GpuName="Resuming install", Variant=variant, Version=version, Installed=true };
            ShowGpuCard(_current);
            ShowUpdateBadge("PENDING", Theme.Yellow);

            if (string.IsNullOrEmpty(installer) || !File.Exists(installer))
            {
                SetStatus("Error", "Cached installer missing — please re-run.", Theme.Red);
                ClearState();
                Dispatcher.Invoke(() => {
                    _actionPanel.Children.Add(ActionBtn("✕","Exit",null,Theme.TextDim,()=>Application.Current.Shutdown(),small:true));
                    _actionPanel.Visibility = Visibility.Visible;
                });
                _busy = false;
                return;
            }

            SetStatus("Installing", $"{variant} {version}...", Theme.Accent);
            bool ok = await Task.Run(() => InstallDriver(installer, variant));

            if (ok)
            {
                if (variant == "Gaming") await Task.Run(() => SetGamingLicense());
                await Task.Run(() => InstallControlPanel());
                ClearState();
                try { if (Directory.Exists(DownloadDir)) Directory.Delete(DownloadDir, true); } catch {}
                Log($"Installation completed: {variant} {version}");
                SetStatus("Done", $"{variant} {version} installed — reboot to activate.", Theme.Green);
                ShowUpdateBadge("INSTALLED", Theme.Green);
                Dispatcher.Invoke(() => {
                    _actionPanel.Children.Clear();
                    _actionPanel.Children.Add(ActionLabel("Complete"));
                    _actionPanel.Children.Add(ActionBtn("↻","Reboot to Activate",
                        "Required to load the new driver",
                        Theme.Green, () => {
                            Process.Start("shutdown","/r /t 5");
                            Application.Current.Shutdown();
                        }));
                    _actionPanel.Children.Add(Spacer(4));
                    _actionPanel.Children.Add(ActionBtn("—","Close", null,
                        Theme.TextDim, () => Application.Current.Shutdown(), small:true));
                    _actionPanel.Visibility = Visibility.Visible;
                });
            }
            else
            {
                SetStatus("Error", "Install failed — state preserved, re-run to retry.", Theme.Red);
                Dispatcher.Invoke(() => {
                    _actionPanel.Children.Add(ActionBtn("✕","Exit",null,Theme.TextDim,()=>Application.Current.Shutdown(),small:true));
                    _actionPanel.Visibility = Visibility.Visible;
                });
            }
            _busy = false;
        }

        // ═════════════════════════════════════════════════════════════════════
        //  DRIVER DETECTION
        // ═════════════════════════════════════════════════════════════════════
        DriverInfo DetectDriver()
        {
            var info = new DriverInfo();
            string smiPath = @"C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe";
            if (!File.Exists(smiPath)) smiPath = "nvidia-smi";
            try {
                var psi = new ProcessStartInfo(smiPath,
                    "--query-gpu=name,driver_version --format=csv,noheader")
                    { RedirectStandardOutput=true, UseShellExecute=false, CreateNoWindow=true };
                var p = Process.Start(psi);
                string o = p.StandardOutput.ReadToEnd().Trim();
                p.WaitForExit();
                if (p.ExitCode==0 && o.Contains(",")) {
                    var parts = o.Split(',');
                    info.GpuName   = parts[0].Trim();
                    info.Version   = parts[1].Trim();
                    info.Installed = true;
                }
            } catch {}
            if (!info.Installed) return info;

            // Detect variant
            try {
                var k = Microsoft.Win32.Registry.LocalMachine
                    .OpenSubKey(@"SOFTWARE\NVIDIA Corporation\Global");
                if (k?.GetValue("vGamingMarketplace")?.ToString() == "2")
                    { info.Variant="Gaming"; return info; }
            } catch {}
            string names = "";
            foreach (string reg in new[]{
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
                @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"})
                try {
                    var k = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(reg);
                    foreach (string s in k?.GetSubKeyNames() ?? new string[0])
                        names += " " + (k.OpenSubKey(s)?.GetValue("DisplayName")?.ToString() ?? "");
                } catch {}
            info.Variant = Regex.IsMatch(names, @"GeForce|Game Ready|Gaming|Studio", RegexOptions.IgnoreCase)
                ? "Gaming" : "GRID";
            return info;
        }

        bool IsGamingSupported(string gpu) =>
            Regex.IsMatch(gpu, @"\bT4\b|\bA10G\b|\bL40S\b", RegexOptions.IgnoreCase) ||
            (Regex.IsMatch(gpu, @"\bL4\b", RegexOptions.IgnoreCase) && !Regex.IsMatch(gpu, @"\bL4[a-zA-Z]", RegexOptions.IgnoreCase));

        // ═════════════════════════════════════════════════════════════════════
        //  S3 FETCH (native HTTP + AWS Sig V4)
        // ═════════════════════════════════════════════════════════════════════
        S3Info FetchS3Version(string bucket, string prefix)
        {
            try {
                string url = $"https://{bucket}.s3.amazonaws.com/?list-type=2&prefix={prefix}&max-keys=50";
                var req = (HttpWebRequest)WebRequest.Create(url);
                req.Timeout = 15000;
                var creds = LoadCreds();
                if (creds.HasValue) SignRequest(req,"GET",bucket,"/","?list-type=2&prefix="+prefix+"&max-keys=50","",creds.Value);
                using var resp = (HttpWebResponse)req.GetResponse();
                using var sr   = new StreamReader(resp.GetResponseStream());
                string xml = sr.ReadToEnd();
                foreach (Match m in Regex.Matches(xml, @"<Key>([^<]*\.exe)</Key>")) {
                    string key = m.Groups[1].Value;
                    var vm = Regex.Match(Path.GetFileName(key), @"(\d+\.\d+)");
                    if (vm.Success) return new S3Info { Version=vm.Groups[1].Value, S3Key=key, S3Bucket=bucket };
                }
                return new S3Info { Version="Unknown", S3Bucket=bucket };
            } catch (Exception ex) {
                Log($"S3 fetch failed ({bucket}): {ex.Message}", "WARN");
                return new S3Info { Version="Unknown", S3Bucket=bucket, Error=true };
            }
        }

        // ═════════════════════════════════════════════════════════════════════
        //  DOWNLOAD
        // ═════════════════════════════════════════════════════════════════════
        string DownloadDriver(S3Info s3)
        {
            if (!Directory.Exists(DownloadDir)) Directory.CreateDirectory(DownloadDir);
            string dest = Path.Combine(DownloadDir, Path.GetFileName(s3.S3Key));
            if (File.Exists(dest)) { Log($"Using cached installer: {dest}"); return dest; }
            string tmp = dest + ".part";
            try {
                string url = $"https://{s3.S3Bucket}.s3.amazonaws.com/{s3.S3Key}";
                var req = (HttpWebRequest)WebRequest.Create(url);
                req.Timeout = 600000;
                var creds = LoadCreds();
                if (creds.HasValue) SignRequest(req,"GET",s3.S3Bucket,"/"+s3.S3Key,"","",creds.Value);
                using var resp = (HttpWebResponse)req.GetResponse();
                long total = resp.ContentLength;
                string fname = Path.GetFileName(s3.S3Key);
                using var stream = resp.GetResponseStream();
                using var fs = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None, 65536);
                byte[] buf = new byte[65536]; int read; long done=0;
                while ((read = stream.Read(buf,0,buf.Length)) > 0) {
                    fs.Write(buf,0,read); done+=read;
                    if (total>0) SetProgress(fname, done*100.0/total, done/1048576, total/1048576);
                }
                File.Move(tmp, dest);
                Log($"Downloaded: {dest}");
                return dest;
            } catch (Exception ex) {
                if (File.Exists(tmp)) File.Delete(tmp);
                Log($"Download failed: {ex.Message}", "ERROR");
                return null;
            }
        }

        // ═════════════════════════════════════════════════════════════════════
        //  UNINSTALL
        // ═════════════════════════════════════════════════════════════════════
        void UninstallDriver()
        {
            foreach (string n in new[]{"nvdm","nvdmui","NVDisplay.Container"})
                try { foreach (var p in Process.GetProcessesByName(n)) p.Kill(); } catch {}

            RunPS(@"Get-AppxPackage -Name 'NVIDIACorp.*' -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue");

            foreach (string reg in new[]{
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
                @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"}) {
                try {
                    var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(reg);
                    foreach (string sub in key?.GetSubKeyNames() ?? new string[0]) {
                        try {
                            var sk = key.OpenSubKey(sub);
                            string dn = sk?.GetValue("DisplayName")?.ToString() ?? "";
                            string us = sk?.GetValue("UninstallString")?.ToString() ?? "";
                            if (!dn.Contains("NVIDIA") || string.IsNullOrEmpty(us)) continue;
                            if (us.Contains("MsiExec")) {
                                var m = Regex.Match(us, @"\{[^}]+\}");
                                if (m.Success) RunWait("msiexec.exe",$"/x {m.Value} /quiet /norestart");
                            } else {
                                var m = Regex.Match(us, @"""?([^""]+\.exe)""?", RegexOptions.IgnoreCase);
                                if (m.Success && File.Exists(m.Groups[1].Value))
                                    RunWait(m.Groups[1].Value,"-s -noreboot");
                            }
                        } catch {}
                    }
                } catch {}
            }

            string nvi2 = @"C:\Program Files\NVIDIA Corporation\Installer2\InstallerCore\NVI2.EXE";
            if (File.Exists(nvi2)) RunWait(nvi2,"-s -noreboot -clean");

            RunPS(@"Get-Service | Where-Object { $_.Name -like 'nv*' } | ForEach-Object { try { Stop-Service $_ -Force -ErrorAction SilentlyContinue } catch {}; sc.exe delete $_.Name 2>&1 | Out-Null }");

            foreach (string d in new[]{
                @"C:\Program Files\NVIDIA Corporation",
                @"C:\Program Files (x86)\NVIDIA Corporation"})
                try { if (Directory.Exists(d)) Directory.Delete(d,true); } catch {}

            Log("Uninstall complete");
        }

        void RegistryCleanup()
        {
            string[] keys = {
                @"SOFTWARE\NVIDIA Corporation",
                @"SOFTWARE\WOW6432Node\NVIDIA Corporation",
                @"SYSTEM\CurrentControlSet\Services\nvlddmkm",
                @"SYSTEM\CurrentControlSet\Services\NvStreamKms",
                @"SYSTEM\CurrentControlSet\Services\NVSvc" };
            int n=0;
            foreach (string k in keys)
                try { Microsoft.Win32.Registry.LocalMachine.DeleteSubKeyTree(k,false); n++; } catch {}
            Log($"Registry cleanup: {n} keys removed");
        }

        // ═════════════════════════════════════════════════════════════════════
        //  INSTALL
        // ═════════════════════════════════════════════════════════════════════
        bool InstallDriver(string installer, string variant)
        {
            try {
                string args = "-s -noreboot -clean" + (variant=="GRID" ? " -noeula" : "");
                var p = Process.Start(new ProcessStartInfo(installer,args)
                    { UseShellExecute=false, CreateNoWindow=true });
                p.WaitForExit();
                Log($"Install exit code: {p.ExitCode}");
                return p.ExitCode==0 || p.ExitCode==14;
            } catch (Exception ex) {
                Log($"Install error: {ex.Message}","ERROR"); return false;
            }
        }

        void SetGamingLicense()
        {
            try {
                var k = Microsoft.Win32.Registry.LocalMachine
                    .CreateSubKey(@"SOFTWARE\NVIDIA Corporation\Global");
                k.SetValue("vGamingMarketplace",2,Microsoft.Win32.RegistryValueKind.DWord);
            } catch {}
            try {
                new WebClient().DownloadFile(
                    "https://nvidia-gaming.s3.amazonaws.com/GridSwCert-Archive/GridSwCertWindows_2024_02_22.cert",
                    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonDocuments),"GridSwCert.txt"));
            } catch {}
        }

        void InstallControlPanel()
        {
            Log("Installing NVIDIA Control Panel from Store");
            try {
                // Try winget first
                string wg = FindOnPath("winget.exe");
                if (!string.IsNullOrEmpty(wg)) {
                    RunWait(wg, "install --id 9NF8H0H7WMLT --source msstore --accept-package-agreements --accept-source-agreements --silent --disable-interactivity");
                    Log("winget install NVIDIA Control Panel done");
                    return;
                }
                // Fallback: fetch MSIX link and sideload
                string html = "";
                try {
                    var req = (HttpWebRequest)WebRequest.Create(
                        "https://store.rg-adguard.net/api/GetFiles?type=PackageFamilyName&url=NVIDIACorp.NVIDIAControlPanel_56jybvy8sckqj&ring=Retail&lang=en-US");
                    req.Timeout=30000;
                    using var resp = (HttpWebResponse)req.GetResponse();
                    html = new StreamReader(resp.GetResponseStream()).ReadToEnd();
                } catch {}
                var mLink = Regex.Match(html, @"href=""(https://[^""]+\.msixbundle)""");
                if (mLink.Success) {
                    string tmp = Path.Combine(Path.GetTempPath(),"NvidiaCP.msixbundle");
                    new WebClient().DownloadFile(mLink.Groups[1].Value, tmp);
                    RunPS($"Add-AppxPackage -Path '{tmp}'");
                    try { File.Delete(tmp); } catch {}
                    Log("MSIX sideload done");
                }
            } catch (Exception ex) {
                Log($"Control Panel install warning: {ex.Message}","WARN");
            }
        }

        // ═════════════════════════════════════════════════════════════════════
        //  STATE / REGISTRY
        // ═════════════════════════════════════════════════════════════════════
        void WriteState(string step,string variant,string ver,string path,string bucket,string key)
        {
            if (!Directory.Exists(WorkDir)) Directory.CreateDirectory(WorkDir);
            File.WriteAllText(StateFile,
                $"{{\"Step\":\"{step}\",\"TargetVariant\":\"{variant}\",\"TargetVersion\":\"{ver}\"," +
                $"\"InstallerPath\":\"{path.Replace("\\","\\\\")}\",\"S3Bucket\":\"{bucket}\",\"S3Key\":\"{key}\"}}");
        }
        string ReadState() {
            try { return File.Exists(StateFile) ? File.ReadAllText(StateFile) : null; } catch { return null; }
        }
        void ClearState() { try { if(File.Exists(StateFile)) File.Delete(StateFile); } catch {} }
        string JsonGet(string json, string key) {
            var m = Regex.Match(json,$"\"{key}\":\"([^\"]+)\"");
            return m.Success ? m.Groups[1].Value.Replace("\\\\","\\") : "";
        }
        void RegisterResume() {
            try {
                string exe = Assembly.GetExecutingAssembly().Location;
                Microsoft.Win32.Registry.LocalMachine
                    .OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Run",true)
                    ?.SetValue("airgpuDriverManagerResume",$"\"{exe}\"");
            } catch {}
        }

        // ═════════════════════════════════════════════════════════════════════
        //  AWS CREDENTIALS + SIG V4
        // ═════════════════════════════════════════════════════════════════════
        (string key, string secret)? LoadCreds()
        {
            try {
                if (!File.Exists(CredsFile)) return null;
                string k="",s="";
                foreach (var line in File.ReadAllLines(CredsFile)) {
                    if (line.Contains("aws_access_key_id"))     k=line.Split('=').Last().Trim();
                    if (line.Contains("aws_secret_access_key")) s=line.Split('=').Last().Trim();
                }
                return k.Length>0 && s.Length>0 ? (k,s) : ((string,string)?)null;
            } catch { return null; }
        }

        void SignRequest(HttpWebRequest req, string method, string bucket,
                         string path, string query, string body,
                         (string key, string secret) creds)
        {
            string date    = DateTime.UtcNow.ToString("yyyyMMdd");
            string amzDate = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
            string host    = $"{bucket}.s3.amazonaws.com";
            string payHash = Sha256(""); // empty body for GET
            string canon   = $"{method}\n{path}\n{query.TrimStart('?')}\nhost:{host}\nx-amz-content-sha256:{payHash}\nx-amz-date:{amzDate}\n\nhost;x-amz-content-sha256;x-amz-date\n{payHash}";
            string scope   = $"{date}/us-east-1/s3/aws4_request";
            string sts     = $"AWS4-HMAC-SHA256\n{amzDate}\n{scope}\n{Sha256(canon)}";
            byte[] sigKey  = Hmac(Hmac(Hmac(Hmac(Encoding.UTF8.GetBytes("AWS4"+creds.secret),date),"us-east-1"),"s3"),"aws4_request");
            string sig     = BitConverter.ToString(Hmac(sigKey,sts)).Replace("-","").ToLower();
            req.Headers["x-amz-date"]           = amzDate;
            req.Headers["x-amz-content-sha256"] = payHash;
            req.Headers["Authorization"]        = $"AWS4-HMAC-SHA256 Credential={creds.key}/{scope},SignedHeaders=host;x-amz-content-sha256;x-amz-date,Signature={sig}";
        }
        static string Sha256(string s) {
            using var h=SHA256.Create();
            return BitConverter.ToString(h.ComputeHash(Encoding.UTF8.GetBytes(s))).Replace("-","").ToLower();
        }
        static byte[] Hmac(byte[] key, string data) {
            using var h=new System.Security.Cryptography.HMACSHA256(key);
            return h.ComputeHash(Encoding.UTF8.GetBytes(data));
        }

        // ═════════════════════════════════════════════════════════════════════
        //  HELPERS
        // ═════════════════════════════════════════════════════════════════════
        void RunWait(string exe, string args) {
            try { Process.Start(new ProcessStartInfo(exe,args){ UseShellExecute=false,CreateNoWindow=true })?.WaitForExit(); } catch {}
        }
        void RunPS(string script) =>
            RunWait("powershell.exe",$"-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"{script.Replace("\"","\\\"").Replace("'","\\'")}\"");
        string FindOnPath(string name) {
            foreach (string p in (Environment.GetEnvironmentVariable("PATH")??"").Split(';'))
                if (File.Exists(Path.Combine(p.Trim(),name))) return Path.Combine(p.Trim(),name);
            return null;
        }
        void Log(string msg, string level="INFO") {
            try {
                if (!Directory.Exists(WorkDir)) Directory.CreateDirectory(WorkDir);
                File.AppendAllText(LogFile,$"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] [{level}] {msg}\n");
            } catch {}
        }

        // ── UI FACTORY HELPERS ────────────────────────────────────────────────
        RowDefinition Row(double h, bool star=false) => star
            ? new RowDefinition { Height=new GridLength(h,GridUnitType.Star) }
            : double.IsNaN(h)
                ? new RowDefinition { Height=GridLength.Auto }
                : new RowDefinition { Height=new GridLength(h) };

        void SetRow(UIElement e, int r, Grid g) { Grid.SetRow(e,r); g.Children.Add(e); }

        Border MkBorder(Color bg, double h=0, Thickness pad=default) =>
            new Border {
                Background=Theme.Brush(bg),
                Height=h>0?h:double.NaN,
                Padding=pad==default?new Thickness(0):pad };

        TextBlock Txt(string t, double sz, Color fg, bool bold=false, double tracking=0) =>
            new TextBlock {
                Text=t, FontSize=sz, FontFamily=new FontFamily("Consolas"),
                Foreground=Theme.Brush(fg),
                FontWeight=bold?FontWeights.Bold:FontWeights.Normal,
                LetterSpacing=tracking,
                VerticalAlignment=VerticalAlignment.Center };

        UIElement ActionLabel(string t) => new TextBlock {
            Text=t.ToUpperInvariant(), FontSize=8, FontFamily=new FontFamily("Consolas"),
            Foreground=Theme.Brush(Theme.TextDim),
            LetterSpacing=1.5, Margin=new Thickness(4,2,0,6) };

        UIElement Spacer(double h) => new Border { Height=h };

        Border ActionBtn(string icon, string title, string sub, Color accent,
                          Action onClick, bool disabled=false, bool small=false)
        {
            var btn = new Border {
                Margin=new Thickness(0,0,0,6),
                Background=disabled ? Theme.BrushA(Theme.Bg,255) : Theme.BrushA(accent,15),
                BorderBrush=disabled ? Theme.Brush(Theme.Border) : Theme.BrushA(accent,50),
                BorderThickness=new Thickness(1),
                Padding=new Thickness(14, small?8:11, 14, small?8:11),
                Cursor=disabled?Cursors.Arrow:Cursors.Hand };

            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width=new GridLength(28) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width=new GridLength(1,GridUnitType.Star) });
            if (!small && !disabled) row.ColumnDefinitions.Add(new ColumnDefinition { Width=GridLength.Auto });

            var ico = Txt(icon, small?10:13, disabled?Theme.TextDim:accent);
            ico.HorizontalAlignment = HorizontalAlignment.Center;
            Grid.SetColumn(ico,0); row.Children.Add(ico);

            var texts = new StackPanel(); Grid.SetColumn(texts,1); row.Children.Add(texts);
            texts.Children.Add(Txt(title, small?10:11, disabled?Theme.TextDim:Theme.TextPri, bold:!small));
            if (!string.IsNullOrEmpty(sub))
                texts.Children.Add(new TextBlock { Text=sub, FontSize=9, FontFamily=new FontFamily("Consolas"),
                    Foreground=Theme.Brush(Theme.TextSec), Margin=new Thickness(0,2,0,0) });

            if (!small && !disabled) {
                var arrow = Txt("›", 14, Theme.TextDim);
                arrow.VerticalAlignment = VerticalAlignment.Center;
                Grid.SetColumn(arrow,2); row.Children.Add(arrow);
            }

            btn.Child = row;

            if (!disabled && onClick!=null) {
                btn.MouseEnter += (_,__) => btn.Background = Theme.BrushA(accent, 28);
                btn.MouseLeave += (_,__) => btn.Background = Theme.BrushA(accent, 15);
                btn.MouseDown  += (_,__) => { if(!_busy) onClick(); };
            }
            return btn;
        }
    }
}
