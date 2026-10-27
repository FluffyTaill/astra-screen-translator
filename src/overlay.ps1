# Screen Translator helper: one long-lived hidden PowerShell process.
# stdin  — JSON lines from the plugin: {"op": ...}
# stdout — JSON lines back:            {"ev": ...}
# Does what Node cannot: global hotkeys, the region picker, screen capture, Windows OCR
# (Windows.Media.Ocr, offline) and the always-on-top translation windows.
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Runtime.WindowsRuntime

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Linq;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace ST {
  public static class Native {
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetWindowDisplayAffinity(IntPtr h, uint a);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int size);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }

    // Per-monitor DPI awareness: every rectangle is in physical pixels, the same ones CopyFromScreen uses
    public static void DpiAware() {
      try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch { }
      try { SetProcessDPIAware(); } catch { }
    }

    public static Rectangle ForegroundRect() {
      RECT r;
      var h = GetForegroundWindow();
      if (h == IntPtr.Zero || DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT))) != 0) return Screen.PrimaryScreen.Bounds;
      return Rectangle.FromLTRB(r.L, r.T, r.R, r.B);
    }
  }

  public static class Io {
    public static readonly ConcurrentQueue<string> Inbox = new ConcurrentQueue<string>();
    static readonly object Gate = new object();
    public static void Send(string json) { lock (Gate) { Console.Out.WriteLine(json); Console.Out.Flush(); } }
    public static void StartReader() {
      var t = new Thread(() => {
        string line;
        while ((line = Console.In.ReadLine()) != null) Inbox.Enqueue(line);
        Inbox.Enqueue("{\"op\":\"exit\"}");
      });
      t.IsBackground = true;
      t.Start();
    }
  }

  // Receives WM_HOTKEY for every registered combination
  public class Hotkeys : NativeWindow {
    public static readonly ConcurrentQueue<int> Pressed = new ConcurrentQueue<int>();
    int count;
    public Hotkeys() { CreateHandle(new CreateParams()); }
    public void Clear() { for (int i = 1; i <= count; i++) Native.UnregisterHotKey(Handle, i); count = 0; }
    // 0x4000 = MOD_NOREPEAT: holding the keys does not fire again and again
    public bool Add(uint mods, uint vk) { count++; return Native.RegisterHotKey(Handle, count, mods | 0x4000, vk); }
    protected override void WndProc(ref Message m) {
      if (m.Msg == 0x0312) Pressed.Enqueue(m.WParam.ToInt32());
      base.WndProc(ref m);
    }
  }

  public static class Shot {
    public static Rectangle Virtual() { return SystemInformation.VirtualScreen; }
    public static Bitmap Grab(Rectangle r) {
      var b = new Bitmap(Math.Max(1, r.Width), Math.Max(1, r.Height), PixelFormat.Format32bppArgb);
      using (var g = Graphics.FromImage(b)) g.CopyFromScreen(r.X, r.Y, 0, 0, b.Size);
      return b;
    }
    // Small text OCRs badly: scale the crop up so letters are at least ~20 px tall
    public static byte[] Png(Bitmap src, Rectangle crop, double scale) {
      int w = Math.Max(1, (int)(crop.Width * scale)), h = Math.Max(1, (int)(crop.Height * scale));
      using (var b = new Bitmap(w, h, PixelFormat.Format32bppArgb)) {
        using (var g = Graphics.FromImage(b)) {
          g.InterpolationMode = InterpolationMode.HighQualityBicubic;
          g.DrawImage(src, new Rectangle(0, 0, w, h), crop, GraphicsUnit.Pixel);
        }
        var ms = new MemoryStream();
        b.Save(ms, ImageFormat.Png);
        return ms.ToArray();
      }
    }
  }

  // Full-screen picker over a frozen screenshot: drag a rectangle, Esc or right click cancels
  public class Picker : Form {
    readonly Bitmap shot;
    readonly Rectangle virt;
    readonly string hint;
    Point start;
    bool dragging;
    public Rectangle Result = Rectangle.Empty;
    Rectangle sel = Rectangle.Empty;

    public Picker(Bitmap shot, Rectangle virt, string hint) {
      this.shot = shot; this.virt = virt; this.hint = hint;
      FormBorderStyle = FormBorderStyle.None;
      StartPosition = FormStartPosition.Manual;
      Bounds = virt;
      TopMost = true;
      ShowInTaskbar = false;
      Cursor = Cursors.Cross;
      KeyPreview = true;
      DoubleBuffered = true;
      KeyDown += (s, e) => { if (e.KeyCode == Keys.Escape) Close(); };
      MouseDown += (s, e) => {
        if (e.Button == MouseButtons.Right) { Close(); return; }
        start = e.Location; dragging = true; sel = Rectangle.Empty;
      };
      MouseMove += (s, e) => {
        if (!dragging) return;
        sel = Rectangle.FromLTRB(Math.Min(start.X, e.X), Math.Min(start.Y, e.Y), Math.Max(start.X, e.X), Math.Max(start.Y, e.Y));
        Invalidate();
      };
      MouseUp += (s, e) => {
        if (!dragging) return;
        dragging = false;
        if (sel.Width >= 8 && sel.Height >= 8) { Result = new Rectangle(sel.X + virt.X, sel.Y + virt.Y, sel.Width, sel.Height); Close(); }
      };
      Shown += (s, e) => { Activate(); Native.SetForegroundWindow(Handle); };
    }

    protected override void OnPaint(PaintEventArgs e) {
      var g = e.Graphics;
      g.DrawImageUnscaled(shot, 0, 0);
      using (var dim = new SolidBrush(Color.FromArgb(120, 0, 0, 0))) {
        var all = new Region(new Rectangle(Point.Empty, Size));
        if (!sel.IsEmpty) all.Exclude(sel);
        g.FillRegion(dim, all);
      }
      if (!sel.IsEmpty) using (var pen = new Pen(Color.FromArgb(255, 232, 176, 74), 2)) g.DrawRectangle(pen, sel);
      using (var f = new Font("Segoe UI", 13f, FontStyle.Bold))
      using (var bg = new SolidBrush(Color.FromArgb(200, 20, 20, 28))) {
        var p = Screen.PrimaryScreen.Bounds;
        var size = g.MeasureString(hint, f);
        var x = p.X - virt.X + (p.Width - size.Width) / 2;
        var y = p.Y - virt.Y + 24;
        g.FillRectangle(bg, x - 14, y - 8, size.Width + 28, size.Height + 16);
        g.DrawString(hint, f, Brushes.White, x, y);
      }
    }
  }

  // The translation window. Never takes focus (the game keeps the keyboard), stays on top, and is
  // invisible to screen capture so live subtitles never re-read themselves.
  // "card" — a popup with a language badge and copy / speak / close buttons;
  // "subs" — a centred subtitle line without buttons.
  public class Bubble : Form {
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int value, int size);

    static readonly Color Bg = Color.FromArgb(30, 31, 40);
    static readonly Color SubsBg = Color.FromArgb(14, 14, 18);
    static readonly Color Border = Color.FromArgb(58, 60, 74);
    static readonly Color Muted = Color.FromArgb(150, 156, 172);
    static readonly Color Accent = Color.FromArgb(232, 176, 74);
    static readonly Color Hover = Color.FromArgb(48, 50, 64);
    const int Pad = 16, HeadH = 30, Btn = 28;

    string text = "", original = "", badge = "";
    float fontSize = 15f;
    bool subs;
    bool roundedByDwm;
    int hot = -1;          // which header button is under the mouse
    Point? dragFrom;
    Point dragWin;
    bool dragged;
    bool copied;
    readonly System.Windows.Forms.Timer life = new System.Windows.Forms.Timer();
    readonly System.Windows.Forms.Timer copiedTimer = new System.Windows.Forms.Timer();
    static readonly string IconFont = FontFamily.Families.Any(f => f.Name == "Segoe Fluent Icons") ? "Segoe Fluent Icons" : "Segoe MDL2 Assets";
    static readonly string TextFont = FontFamily.Families.Any(f => f.Name == "Segoe UI Variable Text") ? "Segoe UI Variable Text" : "Segoe UI";

    public Bubble() {
      FormBorderStyle = FormBorderStyle.None;
      StartPosition = FormStartPosition.Manual;
      TopMost = true;
      ShowInTaskbar = false;
      DoubleBuffered = true;
      BackColor = Bg;
      life.Tick += (s, e) => { life.Stop(); Hide(); };
      copiedTimer.Interval = 1200;
      copiedTimer.Tick += (s, e) => { copiedTimer.Stop(); copied = false; Invalidate(); };
      // subtitles are dragged with the mouse; where they were dropped goes back to the plugin
      MouseDown += (s, e) => {
        if (!subs || e.Button != MouseButtons.Left) return;
        dragFrom = Cursor.Position; dragWin = Location; dragged = false;
      };
      MouseMove += (s, e) => {
        if (subs && dragFrom.HasValue && e.Button == MouseButtons.Left) {
          var p = Cursor.Position;
          if (Math.Abs(p.X - dragFrom.Value.X) + Math.Abs(p.Y - dragFrom.Value.Y) > 3) dragged = true;
          if (dragged) Location = new Point(dragWin.X + p.X - dragFrom.Value.X, dragWin.Y + p.Y - dragFrom.Value.Y);
          return;
        }
        var b = ButtonAt(e.Location); if (b != hot) { hot = b; Invalidate(); }
      };
      MouseUp += (s, e) => {
        if (!subs || !dragFrom.HasValue) return;
        dragFrom = null;
        if (dragged) Io.Send("{\"ev\":\"moved\",\"cx\":" + (Left + Width / 2) + ",\"y\":" + Top + "}");
      };
      MouseLeave += (s, e) => { if (hot != -1) { hot = -1; Invalidate(); } };
      MouseClick += (s, e) => {
        if (subs) return;   // subtitles are switched off with their hotkey, a click only drags
        switch (ButtonAt(e.Location)) {
          case 0: try { Clipboard.SetText(text); copied = true; copiedTimer.Start(); Invalidate(); } catch { } break;
          case 1: Io.Send("{\"ev\":\"speak\",\"text\":" + Json(text) + "}"); break;
          default: Hide(); break;   // the close button or anywhere else
        }
      };
    }

    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
      get {
        var cp = base.CreateParams;
        cp.ExStyle |= 0x08000000 | 0x00000080 | 0x00000008; // NOACTIVATE | TOOLWINDOW | TOPMOST
        cp.ClassStyle |= 0x00020000;                         // CS_DROPSHADOW
        return cp;
      }
    }
    protected override void OnHandleCreated(EventArgs e) {
      base.OnHandleCreated(e);
      Native.SetWindowDisplayAffinity(Handle, 0x11); // WDA_EXCLUDEFROMCAPTURE, Windows 10 2004+
      // Windows 11 rounds the corners itself and keeps the shadow; Windows 10 gets a clipped region
      int round = 2;
      try { roundedByDwm = DwmSetWindowAttribute(Handle, 33, ref round, 4) == 0; } catch { roundedByDwm = false; }
    }

    static string Json(string s) {
      var sb = new System.Text.StringBuilder("\"");
      foreach (var ch in s) {
        if (ch == '"' || ch == '\\') sb.Append('\\').Append(ch);
        else if (ch < ' ') sb.AppendFormat("\\u{0:x4}", (int)ch);
        else sb.Append(ch);
      }
      return sb.Append('"').ToString();
    }

    Rectangle ButtonRect(int i) { return new Rectangle(Width - Pad + 6 - Btn * (3 - i), 8, Btn, Btn - 4); }
    int ButtonAt(Point p) {
      if (subs) return -1;
      for (int i = 0; i < 3; i++) if (ButtonRect(i).Contains(p)) return i;
      return -1;
    }

    Font MainFont() { return new Font(TextFont, subs ? fontSize * 1.15f : fontSize, subs ? FontStyle.Bold : FontStyle.Regular); }
    Font OrigFont() { return new Font(TextFont, Math.Max(8f, fontSize * 0.8f)); }

    // placement: "below" — under the anchor (above it when there is no room), "above", "over" —
    // centred on the anchor (covers the original subtitles), "bottom" — bottom of the anchor's
    // screen, "custom" — where the user dragged it: anchor.X is the centre, anchor.Y the top
    public void Present(Rectangle anchor, string body, string orig, string tag, float size, string placement, int ms, string style) {
      text = body ?? ""; original = orig ?? ""; badge = tag ?? ""; fontSize = size; subs = style == "subs";
      copied = false; hot = -1;
      BackColor = subs ? SubsBg : Bg;
      Opacity = subs ? 0.9 : 0.97;
      var scr = Screen.FromRectangle(anchor).WorkingArea;
      int maxW = subs ? Math.Min(scr.Width - 80, 1100) : Math.Min(scr.Width - 40, Math.Max(420, Math.Min(anchor.Width, 760)));
      int inner = maxW - Pad * 2;
      SizeF main, orgSz = SizeF.Empty;
      using (var g = CreateGraphics()) using (var f = MainFont()) using (var of = OrigFont()) {
        main = g.MeasureString(text, f, inner);
        if (original.Length > 0) orgSz = g.MeasureString(original, of, inner);
      }
      int contentW = (int)Math.Ceiling(Math.Max(main.Width, orgSz.Width));
      int w = subs ? Math.Min(maxW, contentW + Pad * 2 + 6) : maxW;
      int h = (subs ? Pad - 4 : HeadH + 6) + (original.Length > 0 ? (int)orgSz.Height + 6 : 0) + (int)Math.Ceiling(main.Height) + (subs ? Pad - 4 : Pad);
      h = Math.Min(scr.Height - 40, h);
      int x, y;
      if (placement == "bottom") {
        x = scr.X + (scr.Width - w) / 2;
        y = scr.Bottom - h - 70;
      } else if (placement == "custom") {
        x = anchor.X - w / 2;
        y = anchor.Y;
      } else if (placement == "over") {
        x = anchor.X + (anchor.Width - w) / 2;
        y = anchor.Y + (anchor.Height - h) / 2;
      } else if (placement == "above") {
        x = anchor.X + (anchor.Width - w) / 2;
        y = anchor.Y - h - 10;
        if (y < scr.Y + 10) y = anchor.Bottom + 10;
      } else {
        x = subs ? anchor.X + (anchor.Width - w) / 2 : anchor.X;
        x = Math.Max(scr.X + 10, Math.Min(x, scr.Right - w - 10));
        y = anchor.Bottom + 10;
        if (y + h > scr.Bottom - 10) y = anchor.Y - h - 10;
        if (y < scr.Y + 10) y = Math.Max(scr.Y + 10, anchor.Y + 10);
      }
      // keep the whole window on the screen it belongs to
      x = Math.Max(scr.X + 4, Math.Min(x, scr.Right - w - 4));
      y = Math.Max(scr.Y + 4, Math.Min(y, scr.Bottom - h - 4));
      Cursor = subs ? Cursors.SizeAll : Cursors.Default;
      Bounds = new Rectangle(x, y, w, h);
      if (!roundedByDwm) using (var path = Rounded(new Rectangle(0, 0, w, h), 12)) Region = new Region(path);
      Invalidate();
      if (!Visible) Show();
      life.Stop();
      if (ms > 0) { life.Interval = ms; life.Start(); }
    }

    static GraphicsPath Rounded(Rectangle r, int rad) {
      var p = new GraphicsPath();
      p.AddArc(r.X, r.Y, rad * 2, rad * 2, 180, 90);
      p.AddArc(r.Right - rad * 2, r.Y, rad * 2, rad * 2, 270, 90);
      p.AddArc(r.Right - rad * 2, r.Bottom - rad * 2, rad * 2, rad * 2, 0, 90);
      p.AddArc(r.X, r.Bottom - rad * 2, rad * 2, rad * 2, 90, 90);
      p.CloseFigure();
      return p;
    }

    protected override void OnPaint(PaintEventArgs e) {
      var g = e.Graphics;
      g.SmoothingMode = SmoothingMode.AntiAlias;
      g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
      if (!roundedByDwm || !subs) using (var pen = new Pen(Border)) using (var path = Rounded(new Rectangle(0, 0, Width - 1, Height - 1), 12)) g.DrawPath(pen, path);
      int y = subs ? Pad - 4 : HeadH + 6;
      if (!subs) {
        // language badge, e.g. EN → RU
        if (badge.Length > 0) using (var bf = new Font(TextFont, 8.5f, FontStyle.Bold)) {
          var sz = g.MeasureString(badge, bf);
          var r = new RectangleF(Pad - 2, 10, sz.Width + 12, 20);
          using (var bg = new SolidBrush(Color.FromArgb(46, Accent))) using (var path = Rounded(Rectangle.Round(r), 10)) g.FillPath(bg, path);
          using (var fg = new SolidBrush(Accent)) g.DrawString(badge, bf, fg, r.X + 6, r.Y + (r.Height - sz.Height) / 2);
        }
        string[] icons = { copied ? "" : "", "", "" };
        using (var icf = new Font(IconFont, 10.5f)) {
          for (int i = 0; i < 3; i++) {
            var r = ButtonRect(i);
            if (i == hot) using (var hb = new SolidBrush(Hover)) using (var path = Rounded(r, 6)) g.FillPath(hb, path);
            var sz = g.MeasureString(icons[i], icf);
            using (var fg = new SolidBrush(i == hot || (i == 0 && copied) ? Color.White : Muted)) g.DrawString(icons[i], icf, fg, r.X + (r.Width - sz.Width) / 2, r.Y + (r.Height - sz.Height) / 2 + 1);
          }
        }
      }
      int inner = Width - Pad * 2;
      var fmt = new StringFormat();
      if (subs) fmt.Alignment = StringAlignment.Center;
      if (original.Length > 0) using (var of = OrigFont()) using (var mb = new SolidBrush(Muted)) {
        var sz = g.MeasureString(original, of, inner);
        g.DrawString(original, of, mb, new RectangleF(Pad, y, inner, sz.Height), fmt);
        y += (int)sz.Height + 6;
      }
      using (var f = MainFont()) {
        var area = new RectangleF(Pad, y, inner, Height - y - (subs ? Pad - 4 : Pad) + 4);
        if (subs) using (var sh = new SolidBrush(Color.FromArgb(160, 0, 0, 0))) g.DrawString(text, f, sh, new RectangleF(area.X + 1, area.Y + 1, area.Width, area.Height), fmt);
        using (var fg = new SolidBrush(Color.FromArgb(242, 242, 246))) g.DrawString(text, f, fg, area, fmt);
      }
    }
  }
}
'@

[ST.Native]::DpiAware()

# ── Windows OCR through the WinRT projection PowerShell 5.1 has built in ──
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.DataWriter, Windows.Storage.Streams, ContentType = WindowsRuntime]
$script:asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, [Type]$t) { $task = $script:asTask.MakeGenericMethod($t).Invoke($null, @($op)); $null = $task.Wait(-1); $task.Result }
$script:engines = @{}

function Get-Engine([string]$lang) {
  if (-not $script:engines.ContainsKey($lang)) {
    $e = if ($lang) { [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language]::new($lang)) } else { $null }
    if (-not $e) { $e = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
    $script:engines[$lang] = $e
  }
  $script:engines[$lang]
}

$script:allLangs = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { $_.LanguageTag })

# The typographic apostrophe is made at run time: PowerShell reads that character in the source
# as a quote mark, and the script would stop parsing
$script:apos = [string][char]0x2019
$script:wordCase = '^\p{Lu}?[\p{Ll}\p{Mn}''' + $script:apos + '-]*$'
$script:wordUpper = '^[\p{Lu}\p{Mn}''' + $script:apos + '-]+$'

function Script-Of([string]$lang) {
  if ($lang -match '^(ru|uk|be|bg|sr|mk|kk)') { 'cyr' } elseif ($lang -match '^(ja|zh|ko)') { 'cjk' } else { 'lat' }
}

# How much a line looks like real words, 0..1 (+0.05 when it is in the recognizer's own alphabet).
# A recognizer for the wrong language still returns "text", but mangled: Russian read as English
# comes out as "HaXMVlTe HT06bl" (case jumping inside a word, digits for letters), English read as
# Russian mixes Cyrillic and Latin letters. Returns @{ score; letters }
function Score-Text([string]$t, [string]$lang) {
  $letters = 0; $good = 0; $scripts = @{ lat = 0; cyr = 0; cjk = 0 }
  foreach ($w in ($t -split '\s+')) {
    $core = $w -replace '^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$', ''
    $n = ([regex]::Matches($core, '\p{L}')).Count
    if ($n -eq 0) { continue }
    $lat = ([regex]::Matches($core, '[A-Za-zÀ-ɏ]')).Count
    $cyr = ([regex]::Matches($core, '[Ѐ-ӿ]')).Count
    $cjk = $n - $lat - $cyr
    $scripts.lat += $lat; $scripts.cyr += $cyr; $scripts.cjk += $cjk
    $letters += $n
    $oneScript = (($lat -gt 0) + ($cyr -gt 0) + ($cjk -gt 0)) -eq 1
    $noDigits = $core -notmatch '\p{L}\d|\d\p{L}'
    # Word, WORD, word, word's — but not wOrD or WoRD
    $caseOk = $cjk -gt 0 -or $core -cmatch $script:wordCase -or $core -cmatch $script:wordUpper
    if ($oneScript -and $noDigits -and $caseOk) { $good += $n }
  }
  if ($letters -eq 0) { return @{ score = 0; letters = 0 } }
  $dominant = ($scripts.Values | Measure-Object -Maximum).Maximum
  $score = ($good / $letters) * ($dominant / $letters)
  if ($scripts[(Script-Of $lang)] -eq $dominant) { $score += 0.05 }
  @{ score = $score; letters = $letters }
}

# One recognizer's lines with their boxes and scores
function Get-Lines($r, [string]$lang) {
  foreach ($line in $r.Lines) {
    $xs = $line.Words | ForEach-Object { $_.BoundingRect }
    $left = ($xs | ForEach-Object { $_.X } | Measure-Object -Minimum).Minimum
    $right = ($xs | ForEach-Object { $_.X + $_.Width } | Measure-Object -Maximum).Maximum
    $top = ($xs | ForEach-Object { $_.Y } | Measure-Object -Minimum).Minimum
    $bottom = ($xs | ForEach-Object { $_.Y + $_.Height } | Measure-Object -Maximum).Maximum
    $t = $line.Text
    if ($lang -match '^(ja|zh|ko)') { $t = $t -replace '(?<=[\p{IsCJKUnifiedIdeographs}\p{IsHiragana}\p{IsKatakana}\p{IsHangulSyllables}])\s+(?=[\p{IsCJKUnifiedIdeographs}\p{IsHiragana}\p{IsKatakana}\p{IsHangulSyllables}])', '' }
    $s = Score-Text $t $lang
    [pscustomobject]@{ text = $t; lang = $lang; left = $left; right = $right; top = $top; bottom = $bottom; h = $bottom - $top; score = $s.score; letters = $s.letters }
  }
}

function Overlaps($a, $b) {
  $v = [Math]::Min($a.bottom, $b.bottom) - [Math]::Max($a.top, $b.top)
  $hz = [Math]::Min($a.right, $b.right) - [Math]::Max($a.left, $b.left)
  $v -gt [Math]::Min($a.h, $b.h) * 0.5 -and $hz -gt [Math]::Min($a.right - $a.left, $b.right - $b.left) * 0.3
}

# lang: a tag ("en-US") or "auto". With "auto" every installed language reads the picture and
# each LINE keeps the most word-like reading, so English subtitles next to a Russian browser hint
# both come out right. Lines that look like noise (textures in a video frame, stray symbols,
# a lone "tv") are dropped. Returns @{ text; lang }
function Invoke-Ocr([byte[]]$png, [string]$lang, [double]$scale) {
  $stream = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
  $w = New-Object Windows.Storage.Streams.DataWriter($stream.GetOutputStreamAt(0))
  $w.WriteBytes($png)
  $null = Await ($w.StoreAsync()) ([UInt32])
  $dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $sb = Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $tries = if ($lang -and $lang -ne 'auto') { @($lang) } else { $script:allLangs }
  $byLang = @{}
  foreach ($l in $tries) {
    $r = Await ((Get-Engine $l).RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
    $byLang[$l] = @(Get-Lines $r $l)
  }
  # the reading with the most good letters is the skeleton; every line of it may be swapped for
  # another language's reading of the same place
  $base = $tries | Sort-Object { -(($byLang[$_] | ForEach-Object { $_.score * $_.letters } | Measure-Object -Sum).Sum) } | Select-Object -First 1
  $chosen = foreach ($line in $byLang[$base]) {
    $best = $line
    foreach ($l in $tries) {
      if ($l -eq $base) { continue }
      foreach ($o in $byLang[$l]) { if ((Overlaps $line $o) -and $o.score -gt $best.score) { $best = $o } }
    }
    $best
  }
  $kept = @($chosen | Where-Object { $_.score -ge 0.4 -and $_.letters -ge 3 })
  if ($kept.Count -gt 2) {
    # much smaller than the rest of the text: usually noise picked out of a picture
    $median = ($kept | Sort-Object h)[[int]($kept.Count / 2)].h
    $kept = @($kept | Where-Object { $_.h -ge $median * 0.45 })
  }
  $langs = $kept | Group-Object lang | Sort-Object { -(($_.Group | Measure-Object letters -Sum).Sum) }
  @{ text = (Join-Lines ($kept | Sort-Object top)); lang = $(if ($langs) { $langs[0].Name } else { $base }) }
}

# Lines → paragraphs: a gap taller than a line starts a new paragraph, so a wrapped game dialog
# is translated as one sentence instead of line by line
function Join-Lines($lines) {
  $paras = New-Object System.Collections.Generic.List[string]
  $cur = ''; $prev = $null
  foreach ($l in $lines) {
    if ($null -ne $prev -and ($l.top - $prev.bottom) -gt [Math]::Max($l.h, $prev.h) * 0.9) { $paras.Add($cur); $cur = '' }
    $cur = if ($cur) { "$cur $($l.text)" } else { $l.text }
    $prev = $l
  }
  if ($cur) { $paras.Add($cur) }
  ($paras -join "`n")
}

function Send($obj) { [ST.Io]::Send(($obj | ConvertTo-Json -Compress -Depth 5)) }
function RectOf($a) { New-Object System.Drawing.Rectangle([int]$a[0], [int]$a[1], [int]$a[2], [int]$a[3]) }
function ArrOf([System.Drawing.Rectangle]$r) { @($r.X, $r.Y, $r.Width, $r.Height) }
function ScaleFor([System.Drawing.Rectangle]$r) { if ($r.Height -lt 120) { 3.0 } elseif ($r.Height -lt 400) { 2.0 } else { 1.0 } }

function Ocr-Rect([System.Drawing.Rectangle]$rect, [string]$lang) {
  $bmp = [ST.Shot]::Grab($rect)
  try {
    $scale = ScaleFor $rect
    Invoke-Ocr ([ST.Shot]::Png($bmp, (New-Object System.Drawing.Rectangle(0, 0, $rect.Width, $rect.Height)), $scale)) $lang $scale
  } finally { $bmp.Dispose() }
}

$hot = New-Object ST.Hotkeys
$hotIds = @{}
$popup = New-Object ST.Bubble
$subs = New-Object ST.Bubble

function Handle($msg) {
  $c = $msg | ConvertFrom-Json
  switch ($c.op) {
    'hotkeys' {
      $hot.Clear(); $script:hotIds = @{}
      $i = 0; $failed = @()
      foreach ($k in $c.list) {
        $i++; $script:hotIds[$i] = $k.id
        if (-not $hot.Add([uint32]$k.mods, [uint32]$k.vk)) { $failed += $k.id }
      }
      Send @{ ev = 'hotkeys'; failed = $failed }
    }
    'pick' {
      # frozen screenshot first, so a fast-changing game frame stays still while you aim
      $virt = [ST.Shot]::Virtual()
      $bmp = [ST.Shot]::Grab($virt)
      try {
        $f = New-Object ST.Picker($bmp, $virt, [string]$c.hint)
        $null = $f.ShowDialog()
        $sel = $f.Result
        $f.Dispose()
        if ($sel.IsEmpty) { Send @{ ev = 'picked'; req = $c.req; cancel = $true }; return }
        $o = @{ text = $null; lang = '' }
        if ($c.ocr) {
          $crop = New-Object System.Drawing.Rectangle(($sel.X - $virt.X), ($sel.Y - $virt.Y), $sel.Width, $sel.Height)
          $scale = ScaleFor $sel
          $o = Invoke-Ocr ([ST.Shot]::Png($bmp, $crop, $scale)) ([string]$c.lang) $scale
        }
        Send @{ ev = 'picked'; req = $c.req; rect = (ArrOf $sel); text = $o.text; lang = $o.lang }
      } finally { $bmp.Dispose() }
    }
    'ocr' {
      $rect = if ($c.rect) { RectOf $c.rect } elseif ($c.target -eq 'window') { [ST.Native]::ForegroundRect() } else { [System.Windows.Forms.Screen]::PrimaryScreen.Bounds }
      $o = Ocr-Rect $rect ([string]$c.lang)
      Send @{ ev = 'ocr'; req = $c.req; rect = (ArrOf $rect); text = $o.text; lang = $o.lang }
    }
    'show' {
      $b = if ($c.style -eq 'subs') { $subs } else { $popup }
      $b.Present((RectOf $c.rect), [string]$c.text, [string]$c.original, [string]$c.badge, [float]$c.size, [string]$c.where, [int]$c.ms, $(if ($b -eq $subs) { 'subs' } else { 'card' }))
    }
    'hide' {
      if ($c.which -ne 'subs') { $popup.Hide() }
      if ($c.which -ne 'popup') { $subs.Hide() }
    }
    'langs' {
      $list = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { @{ tag = $_.LanguageTag; name = $_.NativeName } })
      Send @{ ev = 'langs'; req = $c.req; list = $list }
    }
    'selftest' {
      # draws a line in memory and reads it back: proves OCR works without looking at the real screen
      $rows = ([string]$c.text -split "`n").Count
      $bmp = New-Object System.Drawing.Bitmap(900, (40 + 60 * $rows))
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      $g.Clear([System.Drawing.Color]::FromArgb(24, 24, 32))
      $g.DrawString([string]$c.text, (New-Object System.Drawing.Font('Segoe UI', 26)), [System.Drawing.Brushes]::White, 12, 18)
      $g.Dispose()
      $t0 = [Diagnostics.Stopwatch]::StartNew()
      try { $o = Invoke-Ocr ([ST.Shot]::Png($bmp, (New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)), 1.0)) ([string]$c.lang) 1.0 } finally { $bmp.Dispose() }
      Send @{ ev = 'selftest'; req = $c.req; text = $o.text; lang = $o.lang; ms = $t0.ElapsedMilliseconds }
    }
    'clip' { if ($c.text) { [System.Windows.Forms.Clipboard]::SetText([string]$c.text) } }
    'exit' { [System.Windows.Forms.Application]::Exit() }
  }
}

# The UI thread polls the inbox and the hotkey queue; every command runs here, in order
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 30
$script:busy = $false
$timer.Add_Tick({
  # the region picker runs a nested message loop; the timer keeps ticking inside it
  if ($script:busy) { return }
  $script:busy = $true
  try {
  $id = 0
  while ([ST.Hotkeys]::Pressed.TryDequeue([ref]$id)) { if ($script:hotIds.ContainsKey($id)) { Send @{ ev = 'hotkey'; id = $script:hotIds[$id] } } }
  $line = $null
  while ([ST.Io]::Inbox.TryDequeue([ref]$line)) {
    try { Handle $line }
    catch {
      $req = $null
      try { $req = ($line | ConvertFrom-Json).req } catch { }
      Send @{ ev = 'error'; req = $req; msg = $_.Exception.Message }
    }
  }
  } finally { $script:busy = $false }
})
$timer.Start()
[ST.Io]::StartReader()
Send @{ ev = 'ready'; pid = $PID }
[System.Windows.Forms.Application]::Run()
