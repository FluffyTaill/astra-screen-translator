// Talks to the PowerShell helper (overlay.ps1): one hidden process for the plugin's lifetime,
// JSON lines both ways. Restarts it if it dies, with a growing pause.
import * as fs from "node:fs";
import * as path from "node:path";
import { spawn, type ChildProcess } from "node:child_process";
import { createInterface } from "node:readline";
import SCRIPT from "./overlay.ps1";

export type Rect = [number, number, number, number];
export interface HotkeySpec { id: string; mods: number; vk: number }
export interface Picked { rect?: Rect; text?: string | null; lang?: string; cancel?: boolean }

type Pending = { resolve: (v: Record<string, unknown>) => void; reject: (e: Error) => void; timer: NodeJS.Timeout };

export class Helper {
  private proc: ChildProcess | null = null;
  private pending = new Map<number, Pending>();
  private seq = 0;
  private stopped = false;
  private restarts = 0;
  private ready: Promise<void> | null = null;
  private hotkeys: HotkeySpec[] = [];
  onHotkey: (id: string) => void = () => {};
  onSpeak: (text: string) => void = () => {};
  onMoved: (cx: number, y: number) => void = () => {};
  onLog: (msg: string) => void = () => {};
  failedHotkeys: string[] = [];

  constructor(private dataDir: string) {}

  // The script is written next to the plugin's data, then read by a tiny bootstrap: it is too big
  // for -EncodedCommand, and a .ps1 run with -File would trip the default execution policy
  start(): Promise<void> {
    if (this.ready) return this.ready;
    this.ready = new Promise<void>((resolve, reject) => {
      fs.mkdirSync(this.dataDir, { recursive: true });
      const file = path.join(this.dataDir, "overlay.ps1");
      fs.writeFileSync(file, "﻿" + SCRIPT, "utf8");
      const boot = `& ([ScriptBlock]::Create([IO.File]::ReadAllText('${file.replace(/'/g, "''")}', [Text.Encoding]::UTF8)))`;
      const proc = spawn("powershell.exe", ["-NoProfile", "-NonInteractive", "-STA", "-WindowStyle", "Hidden",
        "-EncodedCommand", Buffer.from(boot, "utf16le").toString("base64")], { windowsHide: true, stdio: ["pipe", "pipe", "pipe"] });
      this.proc = proc;
      let started = false;
      const fail = setTimeout(() => { if (!started) reject(new Error("помощник не запустился за 30 секунд")); }, 30000);
      createInterface({ input: proc.stdout! }).on("line", (line) => {
        let msg: Record<string, unknown>;
        try { msg = JSON.parse(line); } catch { return; }
        if (msg.ev === "ready") {
          started = true;
          clearTimeout(fail);
          this.restarts = 0;
          if (this.hotkeys.length) void this.setHotkeys(this.hotkeys).catch(() => {});
          resolve();
          return;
        }
        if (msg.ev === "hotkey") { this.onHotkey(String(msg.id)); return; }
        if (msg.ev === "speak") { this.onSpeak(String(msg.text || "")); return; }
        if (msg.ev === "moved") { this.onMoved(Number(msg.cx), Number(msg.y)); return; }
        if (msg.ev === "hotkeys") { this.failedHotkeys = (msg.failed as string[]) || []; }
        const req = Number(msg.req);
        const p = this.pending.get(req);
        if (!p) {
          if (msg.ev === "error") this.onLog(`помощник: ${msg.msg}`);
          return;
        }
        this.pending.delete(req);
        clearTimeout(p.timer);
        if (msg.ev === "error") p.reject(new Error(String(msg.msg)));
        else p.resolve(msg);
      });
      let err = "";
      proc.stderr!.on("data", (d) => { err = (err + d).slice(-2000); });
      proc.on("exit", (code) => {
        clearTimeout(fail);
        this.proc = null;
        this.ready = null;
        for (const [, p] of this.pending) { clearTimeout(p.timer); p.reject(new Error("помощник закрылся")); }
        this.pending.clear();
        if (!started) reject(new Error(`помощник не запустился (код ${code}): ${err.trim().slice(-400)}`));
        if (this.stopped) return;
        this.onLog(`помощник закрылся (код ${code}) ${err.trim().slice(-300)}`);
        const wait = Math.min(60000, 2000 * 2 ** this.restarts++);
        setTimeout(() => { if (!this.stopped) void this.start().catch((e) => this.onLog(e.message)); }, wait).unref();
      });
    });
    return this.ready;
  }

  private send(cmd: Record<string, unknown>) {
    if (!this.proc?.stdin?.writable) throw new Error("помощник не запущен");
    this.proc.stdin.write(JSON.stringify(cmd) + "\n");
  }

  async request(cmd: Record<string, unknown>, timeoutMs = 20000): Promise<Record<string, unknown>> {
    await this.start();
    const req = ++this.seq;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(req); reject(new Error("помощник не ответил")); }, timeoutMs);
      this.pending.set(req, { resolve, reject, timer });
      try { this.send({ ...cmd, req }); } catch (e) { clearTimeout(timer); this.pending.delete(req); reject(e as Error); }
    });
  }

  async fire(cmd: Record<string, unknown>) {
    await this.start();
    this.send(cmd);
  }

  async setHotkeys(list: HotkeySpec[]) {
    this.hotkeys = list;
    if (!this.proc) return;
    this.send({ op: "hotkeys", list });
  }

  // The user picks a region; with ocr=true the text comes back in the same answer (no second capture)
  pick(hint: string, ocr: boolean, lang: string): Promise<Picked> {
    return this.request({ op: "pick", hint, ocr, lang }, 5 * 60000) as Promise<Picked>;
  }

  async ocr(opts: { rect?: Rect; target?: "screen" | "window"; lang: string }) {
    const r = await this.request({ op: "ocr", ...opts });
    return { rect: r.rect as Rect, text: String(r.text || ""), lang: String(r.lang || "") };
  }

  // style: "card" — окно с меткой языка и кнопками, "subs" — строка субтитров
  show(rect: Rect, text: string, opts: { style: "card" | "subs"; where: "below" | "bottom" | "above" | "over" | "custom"; size: number; ms: number; original?: string; badge?: string }) {
    return this.fire({ op: "show", rect, text, ...opts });
  }

  hide(which: "popup" | "subs" | "all" = "all") {
    return this.fire({ op: "hide", which }).catch(() => {});
  }

  async selfTest(text: string, lang: string) {
    const r = await this.request({ op: "selftest", text, lang });
    return { text: String(r.text || ""), lang: String(r.lang || ""), ms: Number(r.ms) };
  }

  async languages(): Promise<{ tag: string; name: string }[]> {
    const r = await this.request({ op: "langs" });
    return (r.list as { tag: string; name: string }[]) || [];
  }

  // SDK завершает процесс плагина через 100 мс после Shutdown, а демон ждёт всю группу процессов:
  // помощника не уговариваем, а сразу закрываем (его горячие клавиши Windows снимет сама)
  stop() {
    this.stopped = true;
    this.proc?.kill();
  }

  get running() { return !!this.proc; }
}
