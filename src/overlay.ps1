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
using System.Collections.Generic;
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
      using (var b = Scaled(src, crop, scale)) return Encode(b);
    }

    // The pictures OCR is shown. With enhance: also a contrast-stretched grey copy and a
    // black-on-white one — game fonts (thin, outlined, over a busy frame) are often read only there
    public static byte[][] Variants(Bitmap src, Rectangle crop, double scale, bool enhance) {
      using (var b = Scaled(src, crop, scale)) {
        var list = new List<byte[]> { Encode(b) };
        if (enhance) {
          using (var c = Filter(b, false)) list.Add(Encode(c));
          using (var t = Filter(b, true)) list.Add(Encode(t));
        }
        return list.ToArray();
      }
    }

    static Bitmap Scaled(Bitmap src, Rectangle crop, double scale) {
      int w = Math.Max(1, (int)(crop.Width * scale)), h = Math.Max(1, (int)(crop.Height * scale));
      var b = new Bitmap(w, h, PixelFormat.Format32bppArgb);
      using (var g = Graphics.FromImage(b)) {
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.DrawImage(src, new Rectangle(0, 0, w, h), crop, GraphicsUnit.Pixel);
      }
      return b;
    }

    static byte[] Encode(Bitmap b) {
      var ms = new MemoryStream();
      b.Save(ms, ImageFormat.Png);
      return ms.ToArray();
    }

    // binary=false: grey, brightness stretched so the 2nd..98th percentile fills the range.
    // binary=true: Otsu threshold; the smaller side of it is taken to be the text and painted black
    // on white (so light text on a dark frame and white text in a black outline both turn into ink)
    static Bitmap Filter(Bitmap src, bool binary) {
      int w = src.Width, h = src.Height, n = w * h;
      var rect = new Rectangle(0, 0, w, h);
      var data = src.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
      var px = new byte[data.Stride * h];
      Marshal.Copy(data.Scan0, px, 0, px.Length);
      src.UnlockBits(data);
      var lum = new byte[n];
      var hist = new int[256];
      for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        int i = y * data.Stride + x * 4;
        int l = (px[i + 2] * 299 + px[i + 1] * 587 + px[i] * 114) / 1000;
        lum[y * w + x] = (byte)l; hist[l]++;
      }
      var lut = new byte[256];
      if (!binary) {
        int lo = 0, hi = 255, acc = 0;
        for (int v = 0; v < 256; v++) { acc += hist[v]; if (acc >= n * 0.02) { lo = v; break; } }
        acc = 0;
        for (int v = 255; v >= 0; v--) { acc += hist[v]; if (acc >= n * 0.02) { hi = v; break; } }
        if (hi - lo < 16) { lo = 0; hi = 255; }
        for (int v = 0; v < 256; v++) lut[v] = (byte)Math.Max(0, Math.Min(255, (v - lo) * 255 / (hi - lo)));
      } else {
        long sum = 0; for (int v = 0; v < 256; v++) sum += (long)v * hist[v];
        long sumB = 0; int wB = 0, t = 128; double best = -1;
        for (int v = 0; v < 256; v++) {
          wB += hist[v]; if (wB == 0) continue;
          int wF = n - wB; if (wF == 0) break;
          sumB += (long)v * hist[v];
          double mB = (double)sumB / wB, mF = (double)(sum - sumB) / wF;
          double between = (double)wB * wF * (mB - mF) * (mB - mF);
          if (between > best) { best = between; t = v; }
        }
        int dark = 0; for (int v = 0; v <= t; v++) dark += hist[v];
        bool textIsDark = dark <= n - dark;
        for (int v = 0; v < 256; v++) lut[v] = (byte)(((v <= t) == textIsDark) ? 0 : 255);
      }
      var outBmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
      var od = outBmp.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
      var op = new byte[od.Stride * h];
      for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        byte g = lut[lum[y * w + x]];
        int i = y * od.Stride + x * 4;
        op[i] = g; op[i + 1] = g; op[i + 2] = g; op[i + 3] = 255;
      }
      Marshal.Copy(op, 0, od.Scan0, op.Length);
      outBmp.UnlockBits(od);
      return outBmp;
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
    // long text: it scrolls with the wheel; while the mouse is over the window it does not hide
    int scroll, contentH, viewTop, viewH, lifeMs;
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
      MouseEnter += (s, e) => life.Stop();
      MouseLeave += (s, e) => {
        if (hot != -1) { hot = -1; Invalidate(); }
        // the mouse left: a little more time to finish the last line, then hide as asked
        if (lifeMs > 0 && Visible) { life.Interval = Math.Max(4000, Math.Min(lifeMs, 15000)); life.Start(); }
      };
      MouseWheel += (s, e) => {
        int max = Math.Max(0, contentH - viewH);
        if (max == 0) return;
        int step = (int)(MainLineHeight() * 3);
        scroll = Math.Max(0, Math.Min(max, scroll - Math.Sign(e.Delta) * step));
        Invalidate();
      };
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
      viewTop = subs ? Pad - 4 : HeadH + 6;
      contentH = (original.Length > 0 ? (int)orgSz.Height + 6 : 0) + (int)Math.Ceiling(main.Height);
      int bottomPad = subs ? Pad - 4 : Pad;
      int h = Math.Min(scr.Height - 40, viewTop + contentH + bottomPad);
      viewH = h - viewTop - bottomPad;
      scroll = 0;
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
      lifeMs = ms;
      // the mouse is already over the new window: keep it until the mouse leaves
      if (ms > 0 && !Bounds.Contains(Cursor.Position)) { life.Interval = ms; life.Start(); }
    }

    float MainLineHeight() { using (var f = MainFont()) return f.GetHeight(); }

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
      bool scrolls = contentH > viewH;
      var fmt = new StringFormat();
      if (subs) fmt.Alignment = StringAlignment.Center;
      // the text area is clipped and shifted by the scroll position
      var clip = g.Clip;
      g.SetClip(new Rectangle(0, viewTop, Width, viewH + 4));
      y = viewTop - scroll;
      if (original.Length > 0) using (var of = OrigFont()) using (var mb = new SolidBrush(Muted)) {
        var sz = g.MeasureString(original, of, inner);
        g.DrawString(original, of, mb, new RectangleF(Pad, y, inner, sz.Height), fmt);
        y += (int)sz.Height + 6;
      }
      using (var f = MainFont()) {
        var area = new RectangleF(Pad, y, inner, contentH + 8);
        if (subs) using (var sh = new SolidBrush(Color.FromArgb(160, 0, 0, 0))) g.DrawString(text, f, sh, new RectangleF(area.X + 1, area.Y + 1, area.Width, area.Height), fmt);
        using (var fg = new SolidBrush(Color.FromArgb(242, 242, 246))) g.DrawString(text, f, fg, area, fmt);
      }
      g.Clip = clip;
      if (scrolls) {
        // a thin bar on the right: where in the text you are
        int track = viewH - 8, thumb = Math.Max(24, track * viewH / contentH);
        int pos = viewTop + 4 + (track - thumb) * scroll / Math.Max(1, contentH - viewH);
        using (var tb = new SolidBrush(Color.FromArgb(40, 255, 255, 255))) g.FillRectangle(tb, Width - 7, viewTop + 4, 3, track);
        using (var th = new SolidBrush(Color.FromArgb(160, Accent))) g.FillRectangle(th, Width - 7, pos, 3, thumb);
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
    $words = @($line.Words | ForEach-Object { [pscustomobject]@{ text = $_.Text; x = $_.BoundingRect.X; y = $_.BoundingRect.Y; w = $_.BoundingRect.Width; h = $_.BoundingRect.Height } })
    [pscustomobject]@{ text = $t; lang = $lang; left = $left; right = $right; top = $top; bottom = $bottom; h = $bottom - $top; score = $s.score; letters = $s.letters; words = $words }
  }
}

# The word under (or nearest to) a point of the picture, from the most word-like reading of its
# line. px/py are in picture pixels. Returns the word, its line and its box, or $null
function Find-Word($byKey, [double]$px, [double]$py) {
  $best = $null; $bestScore = -1
  foreach ($k in $byKey.Keys) {
    foreach ($line in $byKey[$k]) {
      if ($py -lt $line.top - $line.h * 0.6 -or $py -gt $line.bottom + $line.h * 0.6) { continue }
      foreach ($wd in $line.words) {
        # distance from the point to the word box; inside the box is 0
        $dx = [Math]::Max(0, [Math]::Max($wd.x - $px, $px - ($wd.x + $wd.w)))
        $dy = [Math]::Max(0, [Math]::Max($wd.y - $py, $py - ($wd.y + $wd.h)))
        if ($dx -gt $wd.h * 1.5 -or $dy -gt $wd.h) { continue }
        $core = $wd.text -replace '^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$', ''
        if (-not ($core -match '\p{L}')) { continue }
        $s = (Score-Text $core $line.lang).score + $line.score * 0.5 - ($dx + $dy) / [Math]::Max(1, $wd.h)
        if ($k.StartsWith('0|')) { $s += 0.06 }
        if ($s -gt $bestScore) { $best = @{ word = $core; line = $line.text; lang = $line.lang; x = $wd.x; y = $wd.y; w = $wd.w; h = $wd.h }; $bestScore = $s }
      }
    }
  }
  $best
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
function To-SoftwareBitmap([byte[]]$png) {
  $stream = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
  $w = New-Object Windows.Storage.Streams.DataWriter($stream.GetOutputStreamAt(0))
  $w.WriteBytes($png)
  $null = Await ($w.StoreAsync()) ([UInt32])
  $dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
}

# Every picture variant (as is / contrast / black-on-white, all the same size) is read with every
# language; the readings compete line by line
function Read-All($pngs, [string]$lang) {
  $langs = if ($lang -and $lang -ne 'auto') { @($lang) } else { $script:allLangs }
  $byKey = [ordered]@{}
  $v = 0
  foreach ($png in $pngs) {
    $sb = To-SoftwareBitmap $png
    foreach ($l in $langs) {
      $r = Await ((Get-Engine $l).RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
      $byKey["$v|$l"] = @(Get-Lines $r $l)
    }
    $v++
  }
  $byKey
}

function Invoke-Ocr($pngs, [string]$lang, [double]$scale) {
  $byLang = Read-All $pngs $lang
  $tries = @($byLang.Keys)
  # the reading with the most good letters is the skeleton; every line of it may be swapped for
  # another language's reading of the same place
  # Enhanced copies (key "1|…", "2|…") must win clearly: on an easy picture they read the same
  # text with small slips, and a tie goes to the untouched picture
  $penalty = { param($k) if ($k.StartsWith('0|')) { 0 } else { 0.06 } }
  $base = $tries | Sort-Object { -((($byLang[$_] | ForEach-Object { $_.score * $_.letters } | Measure-Object -Sum).Sum) * (1 - (& $penalty $_))) }, { $_ } | Select-Object -First 1
  $chosen = foreach ($line in $byLang[$base]) {
    $best = $line; $bestScore = $line.score - (& $penalty $base)
    foreach ($l in $tries) {
      if ($l -eq $base) { continue }
      foreach ($o in $byLang[$l]) {
        $s = $o.score - (& $penalty $l)
        if ((Overlaps $line $o) -and $s -gt $bestScore) { $best = $o; $bestScore = $s }
      }
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
    Invoke-Ocr ([ST.Shot]::Variants($bmp, (New-Object System.Drawing.Rectangle(0, 0, $rect.Width, $rect.Height)), $scale, $script:enhance)) $lang $scale
  } finally { $bmp.Dispose() }
}

# config op: whether OCR also reads the enhanced copies of the picture (on by default)
$script:enhance = $true
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
          $o = Invoke-Ocr ([ST.Shot]::Variants($bmp, $crop, $scale, $script:enhance)) ([string]$c.lang) $scale
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
      if ($c.style -eq 'faint') {
        # small, low-contrast text: grey on a slightly lighter grey, the way faded UI hints look
        $g.Clear([System.Drawing.Color]::FromArgb(96, 98, 104))
        $g.DrawString([string]$c.text, (New-Object System.Drawing.Font('Segoe UI', 9)), (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(128, 131, 138))), 12, 18)
      } elseif ($c.style -eq 'game') {
        # a busy bright frame with white text in a dark outline, the way game subtitles look
        $rnd = New-Object System.Random 7
        for ($k = 0; $k -lt 160; $k++) {
          $br = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($rnd.Next(120, 256), $rnd.Next(120, 256), $rnd.Next(60, 200)))
          $g.FillEllipse($br, $rnd.Next(-40, 900), $rnd.Next(-40, $bmp.Height), $rnd.Next(20, 120), $rnd.Next(20, 120)); $br.Dispose()
        }
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddString([string]$c.text, (New-Object System.Drawing.FontFamily('Segoe UI')), 0, 30, (New-Object System.Drawing.PointF(12, 18)), [System.Drawing.StringFormat]::GenericDefault)
        $g.SmoothingMode = 'AntiAlias'
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Black), 5
        $g.DrawPath($pen, $path); $g.FillPath([System.Drawing.Brushes]::White, $path)
      } else {
        $g.Clear([System.Drawing.Color]::FromArgb(24, 24, 32))
        $g.DrawString([string]$c.text, (New-Object System.Drawing.Font('Segoe UI', 26)), [System.Drawing.Brushes]::White, 12, 18)
      }
      $g.Dispose()
      $t0 = [Diagnostics.Stopwatch]::StartNew()
      $enh = if ($null -ne $c.enhance) { [bool]$c.enhance } else { $script:enhance }
      $hit = $null
      try {
        $vars = [ST.Shot]::Variants($bmp, (New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)), 1.0, $enh)
        $o = Invoke-Ocr $vars ([string]$c.lang) 1.0
        # px/py — проверка «слова под курсором» на этой же картинке
        if ($null -ne $c.px) { $hit = Find-Word (Read-All $vars ([string]$c.lang)) ([double]$c.px) ([double]$c.py) }
      } finally { $bmp.Dispose() }
      Send @{ ev = 'selftest'; req = $c.req; text = $o.text; lang = $o.lang; ms = $t0.ElapsedMilliseconds; word = $(if ($hit) { $hit.word } else { $null }) }
    }
    'word' {
      # a strip around the cursor, wide enough for the word and its line
      $p = [System.Windows.Forms.Cursor]::Position
      $virt = [ST.Shot]::Virtual()
      $area = [System.Drawing.Rectangle]::Intersect((New-Object System.Drawing.Rectangle(($p.X - 450), ($p.Y - 70), 900, 140)), $virt)
      $bmp = [ST.Shot]::Grab($area)
      try {
        $scale = 3.0
        $byKey = Read-All ([ST.Shot]::Variants($bmp, (New-Object System.Drawing.Rectangle(0, 0, $area.Width, $area.Height)), $scale, $script:enhance)) ([string]$c.lang)
        $hit = Find-Word $byKey (($p.X - $area.X) * $scale) (($p.Y - $area.Y) * $scale)
      } finally { $bmp.Dispose() }
      if (-not $hit) { Send @{ ev = 'word'; req = $c.req; found = $false; rect = @(($p.X - 20), ($p.Y - 10), 40, 20) }; return }
      $r = @([int]($area.X + $hit.x / $scale), [int]($area.Y + $hit.y / $scale), [int][Math]::Max(1, $hit.w / $scale), [int][Math]::Max(1, $hit.h / $scale))
      Send @{ ev = 'word'; req = $c.req; found = $true; word = $hit.word; line = $hit.line; lang = $hit.lang; rect = $r }
    }
    'config' { if ($null -ne $c.enhance) { $script:enhance = [bool]$c.enhance } }
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
      # the line of this script that failed, so a report from the field points at the bug
      $at = $_.InvocationInfo
      Send @{ ev = 'error'; req = $req; msg = "$($_.Exception.Message) (строка $($at.ScriptLineNumber): $($at.Line.Trim()))" }
    }
  }
  } finally { $script:busy = $false }
})
$timer.Start()
[ST.Io]::StartReader()
Send @{ ev = 'ready'; pid = $PID }
[System.Windows.Forms.Application]::Run()
