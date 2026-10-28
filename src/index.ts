/**
 * Screen Translator — плагин Astra: переводит текст с экрана.
 *
 * - горячая клавиша → выделяешь область → перевод появляется рядом, поверх всего;
 * - режим субтитров: выбранная область читается раз в секунду, перевод висит под ней, пока текст меняется;
 * - «переведи экран» голосом: инструменты для ИИ Astra.
 * Текст распознаёт сама Windows (Windows.Media.Ocr) — локально, без интернета; в сеть уходит только
 * распознанный текст, в выбранный переводчик.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { spawn } from "node:child_process";
import { plugin, s, tool, type PluginContext } from "astra-plugin-sdk";
import { Helper, type HotkeySpec, type Rect } from "./helper";
import { dictionary, normalize, RateLimited, similar, translate, worthTranslating, type DictEntry, type Engine, type GlossaryRule } from "./translate";

const ASTRA = path.join(process.env.APPDATA || "", "astra");
const DATA = path.join(ASTRA, "screen-translator");
const SETTINGS = path.join(DATA, "settings.json");
const COMMANDS = path.join(ASTRA, "astra", "config", "commands.json");
const TRIGGER_PREFIX = "plugin__screen_translator__";

// ── настройки ──
export interface Settings {
  hotkeyRegion: string;
  hotkeyLive: string;
  hotkeyWindow: string;
  hotkeyWord: string;      // слово под курсором → карточка с переводом
  ocrLang: string;        // язык текста на экране: "auto" — пробуются все языки Windows
  to: string;             // на какой язык переводить
  engine: Engine;
  deeplKey: string;
  fontSize: number;
  popupSec: number;       // 0 — пока не кликнешь
  liveMs: number;
  livePlace: "over" | "under" | "above" | "bottom" | "custom";
  liveX: number | null;     // куда перетащили субтитры: центр по горизонтали
  liveY: number | null;     // …и верхний край
  liveKeep: number;         // сколько последних фраз видно
  showOriginal: boolean;
  copy: boolean;
  speak: boolean;
  enhance: boolean;        // читать и улучшенные копии снимка (игровые шрифты, бледный текст)
  glossary: GlossaryRule[]; // свой словарь: термин → перевод (пусто — не переводить)
}
export const DEFAULTS: Settings = {
  hotkeyRegion: "Ctrl+Alt+T", hotkeyLive: "Ctrl+Alt+Y", hotkeyWindow: "Ctrl+Alt+W", hotkeyWord: "Ctrl+Alt+D",
  ocrLang: "auto", to: "ru", engine: "google", deeplKey: "", fontSize: 15, popupSec: 15,
  liveMs: 500, livePlace: "over", liveX: null, liveY: null, liveKeep: 3, showOriginal: false, copy: false, speak: false,
  enhance: true, glossary: []
};

export function cleanSettings(raw: unknown): Settings {
  const r = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  const str = (k: keyof Settings, max = 64) => (typeof r[k] === "string" ? (r[k] as string).trim().slice(0, max) : DEFAULTS[k] as string);
  const bool = (k: keyof Settings) => (typeof r[k] === "boolean" ? r[k] as boolean : DEFAULTS[k] as boolean);
  const num = (k: keyof Settings, min: number, max: number) => {
    const n = Number(r[k]);
    return Number.isFinite(n) ? Math.min(max, Math.max(min, Math.round(n))) : DEFAULTS[k] as number;
  };
  const hotkey = (k: keyof Settings) => {
    const v = typeof r[k] === "string" ? (r[k] as string).trim() : DEFAULTS[k] as string;
    return v === "" || parseHotkey(v) ? v : DEFAULTS[k] as string;
  };
  return {
    hotkeyRegion: hotkey("hotkeyRegion"), hotkeyLive: hotkey("hotkeyLive"), hotkeyWindow: hotkey("hotkeyWindow"), hotkeyWord: hotkey("hotkeyWord"),
    ocrLang: str("ocrLang") === "auto" || /^[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})*$/.test(str("ocrLang")) ? str("ocrLang") : DEFAULTS.ocrLang,
    to: /^[a-z]{2,3}(-[A-Za-z]{2,4})?$/.test(str("to")) ? str("to") : DEFAULTS.to,
    engine: r.engine === "deepl" ? "deepl" : "google",
    deeplKey: str("deeplKey", 200),
    fontSize: num("fontSize", 9, 40), popupSec: num("popupSec", 0, 600), liveMs: num("liveMs", 250, 10000),
    livePlace: (["over", "under", "above", "bottom", "custom"] as const).find((p) => p === r.livePlace) || DEFAULTS.livePlace,
    liveX: Number.isFinite(Number(r.liveX)) && r.liveX !== null ? Math.round(Number(r.liveX)) : null,
    liveY: Number.isFinite(Number(r.liveY)) && r.liveY !== null ? Math.round(Number(r.liveY)) : null,
    liveKeep: num("liveKeep", 1, 6),
    showOriginal: bool("showOriginal"), copy: bool("copy"), speak: bool("speak"), enhance: bool("enhance"),
    glossary: cleanGlossary(r.glossary)
  };
}

export function cleanGlossary(raw: unknown): GlossaryRule[] {
  if (!Array.isArray(raw)) return [];
  return raw.filter((x) => x && typeof x === "object" && typeof x.from === "string" && x.from.trim())
    .slice(0, 300)
    .map((x) => ({ from: String(x.from).trim().slice(0, 80), to: typeof x.to === "string" ? x.to.trim().slice(0, 120) : "" }));
}

// «Ctrl+Alt+T» → флаги RegisterHotKey и код клавиши
const MODS: Record<string, number> = { alt: 1, ctrl: 2, control: 2, shift: 4, win: 8 };
const KEYS: Record<string, number> = {
  space: 32, enter: 13, tab: 9, esc: 27, insert: 45, delete: 46, home: 36, end: 35, pageup: 33, pagedown: 34,
  pause: 19, printscreen: 44, up: 38, down: 40, left: 37, right: 39, "`": 192, "~": 192, "-": 189, "=": 187,
  "[": 219, "]": 221, ";": 186, "'": 222, ",": 188, ".": 190, "/": 191, "\\": 220,
  num0: 96, num1: 97, num2: 98, num3: 99, num4: 100, num5: 101, num6: 102, num7: 103, num8: 104, num9: 105
};
export function parseHotkey(s: string): { mods: number; vk: number } | null {
  const parts = s.split("+").map((p) => p.trim().toLowerCase()).filter(Boolean);
  if (!parts.length) return null;
  let mods = 0, vk = 0;
  for (const p of parts) {
    if (MODS[p]) mods |= MODS[p];
    else if (/^[a-z0-9]$/.test(p)) vk = p.toUpperCase().charCodeAt(0);
    else if (/^f([1-9]|1[0-9]|2[0-4])$/.test(p)) vk = 111 + Number(p.slice(1));
    else if (KEYS[p]) vk = KEYS[p];
    else return null;
  }
  // без модификатора можно только F-клавиши и спецклавиши: буква без Ctrl/Alt сломала бы набор текста
  if (!vk || (!mods && vk >= 48 && vk <= 90)) return null;
  return { mods, vk };
}

let settings = load(SETTINGS, DEFAULTS, cleanSettings);
function load<T>(file: string, fallback: T, clean: (x: unknown) => T): T {
  try { return clean(JSON.parse(fs.readFileSync(file, "utf8"))); } catch { return clean(fallback); }
}
function save(file: string, value: unknown) {
  fs.mkdirSync(DATA, { recursive: true });
  fs.writeFileSync(file, JSON.stringify(value, null, 2));
}

// ── помощник и контекст ──
const helper = new Helper(DATA);
let ctxRef: PluginContext | null = null;
let lastError = "";

function warn(msg: string) {
  lastError = msg;
  void ctxRef?.warn(`Screen Translator: ${msg}`).catch(() => {});
}

function applyHotkeys() {
  const list: HotkeySpec[] = [];
  for (const [id, key] of [["region", settings.hotkeyRegion], ["live", settings.hotkeyLive], ["window", settings.hotkeyWindow], ["word", settings.hotkeyWord]] as const) {
    const k = key && parseHotkey(key);
    if (k) list.push({ id, ...k });
  }
  return helper.setHotkeys(list);
}

// Голос Astra синтезирует фразу целиком и бросает её, если не уложился в ~12 с (так было с 826
// символами). Поэтому длинный перевод уходит частями по предложениям, каждая — следующей, когда
// предыдущая почти договорена. Новый перевод обрывает недосказанный.
export function speechChunks(text: string, max = 200): string[] {
  const t = text.replace(/\s+/g, " ").trim();
  const sentences = t.match(/[^.!?…]+[.!?…]+["»)]*\s*|[^.!?…]+$/g) || [];
  const out: string[] = [];
  let cur = "";
  for (let s of sentences) {
    s = s.trim();
    // слишком длинное предложение режем по запятым, потом по пробелам
    while (s.length > max) {
      const cut = s.slice(0, max);
      const at = Math.max(cut.lastIndexOf(", "), cut.lastIndexOf("; "), cut.lastIndexOf(": "));
      const end = at > max * 0.4 ? at + 1 : cut.lastIndexOf(" ") > 0 ? cut.lastIndexOf(" ") : max;
      if (cur) { out.push(cur); cur = ""; }
      out.push(s.slice(0, end).trim());
      s = s.slice(end).trim();
    }
    if (!s) continue;
    if (cur && cur.length + 1 + s.length > max) { out.push(cur); cur = s; } else cur = cur ? `${cur} ${s}` : s;
  }
  if (cur) out.push(cur);
  return out;
}

// ~13 символов в секунду при скорости 0.95 (по логу голоса Astra); следующая часть уходит чуть
// раньше конца, чтобы успела синтезироваться
const speechMs = (s: string) => Math.max(1200, (s.length / 13) * 1000 - 1200);
let speechRun = 0;

async function say(text: string) {
  const run = ++speechRun;
  for (const part of speechChunks(text)) {
    if (run !== speechRun || !ctxRef) return;
    await ctxRef.fireTrigger("st_say", { text: part }).catch((e) => warn(`озвучка: ${(e as Error).message}`));
    await new Promise((r) => setTimeout(r, speechMs(part)));
  }
}

const badgeOf = (from: string) => (from ? `${from.split("-")[0].toUpperCase()} → ${settings.to.split("-")[0].toUpperCase()}` : "");

async function deliver(rect: Rect, original: string, style: "card" | "subs", where: "below" | "bottom", ms: number, speak: boolean) {
  const t = await translate(original, settings.to, settings.engine, settings.deeplKey, settings.glossary);
  await helper.show(rect, t.text, { style, where, size: settings.fontSize, ms, original: settings.showOriginal ? original : "", badge: badgeOf(t.from) });
  if (settings.copy) await helper.fire({ op: "clip", text: t.text }).catch(() => {});
  if (speak && settings.speak) void say(t.text);
  return t;
}

const popupMs = () => settings.popupSec * 1000;

// Выделить область → перевести → показать рядом
export async function translateRegion(): Promise<string> {
  if (live.on) stopLive();
  const p = await helper.pick("Выдели текст для перевода · Esc — отмена", true, settings.ocrLang);
  if (p.cancel || !p.rect) return "Отменено.";
  const text = (p.text || "").trim();
  if (!worthTranslating(text)) {
    await helper.show(p.rect, "Не нашла здесь текста. Если он на языке, которого нет в Windows (японский, китайский…), добавь язык — подсказка на странице плагина.",
      { style: "card", where: "below", size: settings.fontSize, ms: 6000 });
    return "В выделенной области не нашлось текста.";
  }
  const t = await deliver(p.rect, text, "card", "below", popupMs(), true);
  return `Оригинал: ${text}\nПеревод: ${t.text}`;
}

// Весь экран или активное окно — для голоса и третьей горячей клавиши
// Слово под курсором: карточка с переводом, транскрипцией и значениями по частям речи
export function wordCard(d: DictEntry, glossaryHit?: GlossaryRule) {
  const head = glossaryHit ? (glossaryHit.to || d.word) : d.text;
  const lines = [head, ...d.senses.filter((s) => s.words.length).slice(0, 4).map((s) => `${s.pos} ${s.words.join(", ")}`)];
  return { text: lines.join("\n"), original: d.transcription ? `${d.word}   [${d.transcription}]` : d.word };
}

export async function lookupWord(): Promise<string> {
  const r = await helper.word(settings.ocrLang);
  if (!r.found) {
    await helper.show(r.rect, "Не нашла слово под курсором — наведи мышь прямо на него.", { style: "card", where: "below", size: settings.fontSize, ms: 2500 });
    return "Под курсором нет слова.";
  }
  const g = settings.glossary.find((x) => x.from.trim().toLowerCase() === r.word.toLowerCase());
  let d: DictEntry;
  try {
    d = await dictionary(r.word, settings.to);
  } catch (e) {
    // ошибка видна рядом со словом, а не только в журнале
    await helper.show(r.rect, `${r.word}
${(e as Error).message}`, { style: "card", where: "below", size: settings.fontSize, ms: 6000 });
    throw e;
  }
  const card = wordCard(d, g);
  await helper.show(r.rect, card.text, { style: "card", where: "below", size: settings.fontSize, ms: popupMs(), original: card.original, badge: badgeOf(d.from) });
  return `${r.word}: ${card.text}`;
}

// ── языки распознавания Windows одной кнопкой ──
// Add-WindowsCapability требует прав администратора: Windows сама спросит подтверждение (UAC)
export const OCR_PACKS: { tag: string; name: string }[] = [
  { tag: "ja-JP", name: "Японский" }, { tag: "zh-CN", name: "Китайский (упрощённый)" }, { tag: "zh-TW", name: "Китайский (традиционный)" },
  { tag: "ko-KR", name: "Корейский" }, { tag: "de-DE", name: "Немецкий" }, { tag: "fr-FR", name: "Французский" },
  { tag: "es-ES", name: "Испанский" }, { tag: "it-IT", name: "Итальянский" }, { tag: "pt-BR", name: "Португальский" },
  { tag: "pl-PL", name: "Польский" }, { tag: "uk-UA", name: "Украинский" }, { tag: "tr-TR", name: "Турецкий" },
  { tag: "en-US", name: "Английский" }, { tag: "ru-RU", name: "Русский" }
];
const ocrInstall = { tag: "", state: "idle" as "idle" | "running" | "done" | "error", message: "" };

export function installCommand(tag: string) {
  if (!OCR_PACKS.some((p) => p.tag === tag)) throw new Error(`нет такого языка: ${tag}`);
  const inner = `Add-WindowsCapability -Online -Name 'Language.OCR~~~${tag}~0.0.1.0' | Out-Null`;
  // внешний PowerShell без прав запускает внутренний с правами администратора и ждёт его
  return `$p = Start-Process powershell -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-Command', "${inner}"); exit $p.ExitCode`;
}

async function installOcrLanguage(tag: string) {
  Object.assign(ocrInstall, { tag, state: "running", message: "Windows спросит разрешение — нажми «Да». Установка займёт минуту-две." });
  const code = await new Promise<number>((resolve) => {
    const p = spawn("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", installCommand(tag)], { windowsHide: true });
    let err = "";
    p.stderr.on("data", (d) => { err += d; });
    p.on("exit", (c) => {
      if (c !== 0 && /cancel|отмен/i.test(err)) ocrInstall.message = "Установка отменена в окне Windows.";
      resolve(c ?? 1);
    });
  });
  if (code !== 0) {
    Object.assign(ocrInstall, { state: "error", message: ocrInstall.message.startsWith("Установка отменена") ? ocrInstall.message : `Не установилось (код ${code}). Можно поставить вручную: Параметры → Время и язык → Язык и регион.` });
    return;
  }
  await helper.restart().catch((e) => warn((e as Error).message));
  languagesCache = null;
  const langs = await helper.languages().catch(() => []);
  const ok = langs.some((l) => l.tag.toLowerCase().startsWith(tag.split("-")[0].toLowerCase()));
  Object.assign(ocrInstall, ok
    ? { state: "done", message: `Готово: ${OCR_PACKS.find((p) => p.tag === tag)?.name} распознаётся.` }
    : { state: "error", message: "Windows установила пакет, но язык пока не виден — перезагрузи компьютер." });
}

export async function translateWhole(target: "screen" | "window", show: boolean): Promise<string> {
  const r = await helper.ocr({ target, lang: settings.ocrLang });
  const text = r.text.trim();
  if (!worthTranslating(text)) return "На экране не нашлось текста для перевода.";
  // ответ получает ИИ Astra и сам его озвучит — свой голос поверх не нужен
  const t = show ? await deliver(r.rect, text, "card", "below", popupMs(), false) : await translate(text, settings.to, settings.engine, settings.deeplKey, settings.glossary);
  return `Оригинал: ${text}\nПеревод: ${t.text}`;
}

// ── субтитры ──
// Каждая фраза (абзац на экране) переводится отдельно и остаётся видна ещё несколько секунд, так
// что быстро сменяющиеся реплики встают друг под другом, а не теряются. Дописывающаяся фраза
// (автосубтитры YouTube появляются по слову) обновляется на месте. Новая фраза показывается со
// второго чтения: случайный «текст» из кадра видео мелькает на одно чтение.
export interface Phrase { src: string; text: string; firstSeen: number; lastSeen: number; asked: string }
export interface LiveState { phrases: Phrase[]; pending: Map<string, number> }

const sameOrGrown = (a: string, b: string) => {
  if (similar(a, b) >= 0.8) return true;
  const x = normalize(a), y = normalize(b);
  return x.length >= 6 && y.length >= 6 && (x.startsWith(y) || y.startsWith(x) || x.includes(y) || y.includes(x));
};

// Одно чтение области → обновлённый список фраз. Возвращает фразы, которым нужен (новый) перевод
export function liveUpdate(st: LiveState, paragraphs: string[], now: number, holdMs: number): Phrase[] {
  const todo: Phrase[] = [];
  const seenNow = new Set<string>();
  for (const p of paragraphs.map((x) => x.trim()).filter(worthTranslating)) {
    const known = st.phrases.find((f) => sameOrGrown(f.src, p));
    if (known) {
      known.lastSeen = now;
      if (normalize(p).length > normalize(known.src).length || similar(p, known.src) < 0.95) known.src = p;
      if (known.asked !== known.src) todo.push(known);
      continue;
    }
    const key = normalize(p);
    seenNow.add(key);
    const prevKey = [...st.pending.keys()].find((k) => sameOrGrown(k, key));
    if (prevKey !== undefined) {
      st.pending.delete(prevKey);
      const f: Phrase = { src: p, text: "", firstSeen: now, lastSeen: now, asked: "" };
      st.phrases.push(f);
      todo.push(f);
    } else {
      st.pending.set(key, now);
    }
  }
  for (const [k, t] of st.pending) if (!seenNow.has(k) && now - t > 1500) st.pending.delete(k);
  st.phrases = st.phrases.filter((f) => now - f.lastSeen <= holdMs);
  return todo;
}

const live = {
  on: false, rect: null as Rect | null, busy: false, timer: null as NodeJS.Timeout | null,
  state: { phrases: [], pending: new Map() } as LiveState, shown: "", pauseUntil: 0
};

function liveWhere(): { where: string; anchor: Rect } {
  const r = live.rect!;
  if (settings.livePlace === "custom" && settings.liveX !== null && settings.liveY !== null) return { where: "custom", anchor: [settings.liveX, settings.liveY, 0, 0] };
  return { where: settings.livePlace === "under" ? "below" : settings.livePlace === "custom" ? "over" : settings.livePlace, anchor: r };
}

async function renderLive() {
  const visible = live.state.phrases.filter((f) => f.text).slice(-settings.liveKeep);
  const key = visible.map((f) => f.text).join("\n");
  if (key === live.shown) return;
  live.shown = key;
  if (!visible.length) { await helper.hide("subs"); return; }
  const { where, anchor } = liveWhere();
  // новая фраза — ярко внизу, предыдущие — бледнее над ней
  await helper.show(anchor, visible[visible.length - 1].text, {
    style: "subs", where: where as "below", size: settings.fontSize, ms: 0,
    original: visible.slice(0, -1).map((f) => f.text).join("\n")
  });
}

export async function startLive(rect?: Rect): Promise<string> {
  if (!rect) {
    const p = await helper.pick("Выдели область, где появляется текст (субтитры, диалог) · Esc — отмена", false, settings.ocrLang);
    if (p.cancel || !p.rect) return "Отменено.";
    rect = p.rect;
  }
  stopLive();
  Object.assign(live, { on: true, rect, busy: false, state: { phrases: [], pending: new Map() }, shown: "" });
  live.timer = setInterval(() => void liveTick(), settings.liveMs);
  const { where, anchor } = liveWhere();
  await helper.show(anchor, "Субтитры включены — жду текст… (окно можно перетащить мышкой)", { style: "subs", where: where as "below", size: settings.fontSize, ms: 3000 });
  return "Субтитры включены: перевожу выбранную область, пока не выключишь той же клавишей.";
}

export function stopLive() {
  if (live.timer) clearInterval(live.timer);
  live.timer = null;
  const was = live.on;
  live.on = false;
  void helper.hide("subs");
  return was ? "Субтитры выключены." : "Субтитры и так выключены.";
}

async function liveTick() {
  if (!live.on || live.busy || !live.rect || Date.now() < live.pauseUntil) return;
  live.busy = true;
  try {
    const r = await helper.ocr({ rect: live.rect, lang: settings.ocrLang });
    const todo = liveUpdate(live.state, r.text.split("\n"), Date.now(), Math.max(3000, settings.liveMs * 6));
    // переводы — параллельно и без ожидания следующего чтения; каждая фраза появляется, как только готова
    for (const f of todo) {
      const asked = f.src;
      f.asked = asked;
      void translate(asked, settings.to, settings.engine, settings.deeplKey, settings.glossary).then((t) => {
        if (f.src === asked || !f.text) f.text = t.text;
        if (live.on) return renderLive();
      }).catch((e) => {
        // Google ограничил запросы — субтитры отдыхают полминуты, а не долбят его каждые полсекунды
        if (e instanceof RateLimited && Date.now() >= live.pauseUntil) {
          live.pauseUntil = Date.now() + 30000;
          void helper.show(live.rect!, "Google временно ограничил перевод — продолжу через 30 секунд", { style: "subs", where: liveWhere().where as "below", size: settings.fontSize, ms: 4000 });
        }
        warn(`субтитры: ${(e as Error).message}`);
      });
    }
    await renderLive();
  } catch (e) {
    warn(`субтитры: ${(e as Error).message}`);
  } finally {
    live.busy = false;
  }
}

async function onHotkey(id: string) {
  try {
    if (id === "region") await translateRegion();
    else if (id === "live") { if (live.on) stopLive(); else await startLive(); }
    else if (id === "window") await translateWhole("window", true);
    else if (id === "word") await lookupWord();
  } catch (e) {
    warn((e as Error).message);
  }
}
helper.onHotkey = (id) => void onHotkey(id);
helper.onLog = (m) => warn(m);
helper.onSpeak = (text) => void say(text);
// субтитры перетащили мышкой — запоминаем место
helper.onMoved = (cx, y) => {
  settings = cleanSettings({ ...settings, livePlace: "custom", liveX: cx, liveY: y });
  save(SETTINGS, settings);
};

// ── команда Astra «сказать перевод» (как в Deadlock Coach и Anim Studio) ──
const SAY_SPEC = { trigger: "st_say", name: "Перевод: сказать вслух",
  action: { text: "{text}", tts_pitch: 1, tts_speed: 0.95, type: "speak", use_settings_voice: false, voices: {} } };

function readCommands(): unknown[] | null {
  try {
    const list = JSON.parse(fs.readFileSync(COMMANDS, "utf8").replace(/^﻿/, ""));
    return Array.isArray(list) ? list : null;
  } catch {
    return null;
  }
}

function commandStatus(ctx?: PluginContext) {
  const list = (readCommands() || []) as { triggers?: { handler_id?: string }[] }[];
  return {
    inFile: list.some((c) => (c.triggers || []).some((t) => t.handler_id === TRIGGER_PREFIX + SAY_SPEC.trigger)),
    listening: [...(ctx?.activeTriggers || [])].some((a) => a === SAY_SPEC.trigger || a === TRIGGER_PREFIX + SAY_SPEC.trigger)
  };
}

function createCommand(ctx: PluginContext) {
  const list = readCommands();
  if (!list) throw new Error(`не читается ${COMMANDS}`);
  if (commandStatus(ctx).inFile) return { added: 0 };
  const stamp = new Date().toISOString();
  const handler = TRIGGER_PREFIX + SAY_SPEC.trigger;
  const t = Date.now();
  const tn = `node_1_${t}`, an = `node_2_${t}`, edge = `xy-edge__${tn}-${an}`;
  list.push({
    actions: [SAY_SPEC.action], created_at: stamp, description: "Создано плагином Screen Translator", editor_mode: "graph",
    enabled: true, execution: {}, id: globalThis.crypto.randomUUID(), name: SAY_SPEC.name, priority: 4,
    slash_description: "", slash_enabled: false, tags: [],
    triggers: [{ config: {}, handler_id: handler, type: "dynamic" }], updated_at: stamp,
    workflow: {
      edge_order: [edge],
      edges: { [edge]: { id: edge, source_node: tn, source_port: "default", target_node: an, target_port: "default" } },
      nodes: {
        [tn]: { data: { config: {}, trigger_type: handler }, id: tn, label: "", node_type: "trigger", position_x: 0, position_y: 0 },
        [an]: { data: { action: SAY_SPEC.action, action_type: SAY_SPEC.action.type, config: SAY_SPEC.action, wait_for_completion: "false" },
          id: an, label: "", node_type: "action", position_x: 360, position_y: 0 }
      }
    }
  });
  if (!fs.existsSync(COMMANDS + ".before-screen-translator")) fs.copyFileSync(COMMANDS, COMMANDS + ".before-screen-translator");
  fs.writeFileSync(COMMANDS, JSON.stringify(list, null, 2));
  return { added: 1 };
}

// ── плагин ──
let languagesCache: { tag: string; name: string }[] | null = null;
const param = (p: unknown, k: string) => (p && typeof p === "object" ? (p as Record<string, unknown>)[k] : undefined);
// страница не ждёт выделения области: мост обрывает вызов через ~10 с
const background = (fn: () => Promise<unknown>) => { void fn().catch((e) => warn((e as Error).message)); return { started: true }; };

export { Helper };
export { similar, translate, worthTranslating, dictionary, protect, restore, RateLimited } from "./translate";
export const app = plugin({
  id: "screen-translator",
  tools: {
    screen_translate: tool({
      description: "Переводит текст с экрана пользователя: распознаёт весь экран или активное окно (локально, Windows OCR) и переводит на язык из настроек. Используй на «переведи, что на экране», «что тут написано», «переведи это окно». Translates on-screen text.",
      input: s.object({
        target: s.enum(["screen", "window"]).optional().describe("screen — весь главный экран (по умолчанию), window — только активное окно"),
        show: s.boolean().optional().describe("Показать перевод поверх экрана (по умолчанию да)")
      }),
      run: async ({ target, show }) => translateWhole(target || "screen", show !== false)
    }),
    screen_translate_region: tool({
      description: "Просит пользователя выделить мышкой область экрана и переводит текст в ней; перевод появляется рядом с областью. Используй на «переведи вот это», «переведи кусок экрана». Ждёт, пока пользователь выделит область. Lets the user select a screen region and translates it.",
      input: s.object({}),
      run: async () => translateRegion()
    }),
    screen_subtitles: tool({
      description: "Включает или выключает живые субтитры: выбранная область экрана (диалоги в игре, субтитры видео) переводится каждую секунду, перевод висит под ней. Turns live on-screen translation on or off.",
      input: s.object({ on: s.boolean().describe("true — включить (пользователь выделит область), false — выключить") }),
      run: async ({ on }) => (on ? startLive() : stopLive())
    })
  },
  triggers: {
    st_say: { label: "Перевод с экрана ({text})", fields: [] }
  },
  onStart: async (ctx) => {
    ctxRef = ctx;
    if (process.env.ST_NO_HELPER === "1") return; // тесты в процессе: без PowerShell и глобальных клавиш
    void applyHotkeys();
    void helper.setConfig({ enhance: settings.enhance });
    await helper.start().catch((e) => warn((e as Error).message));
  },
  onShutdown: () => {
    stopLive();
    helper.stop();
  },
  ui: {
    contributions: [{
      id: "screen-translator", slot: "page.custom", label: "Перевод с экрана",
      iconSvg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7V5h2M18 5h2v2M20 17v2h-2M6 19H4v-2"/><path d="M8 9h5M10.5 9v6M14 15l2-5 2 5M14.6 13.5h2.8"/></svg>',
      url: "index.html", width: 0, height: 0, transparent: true
    }],
    onCall: {
      getState: async (_p: unknown, ctx: PluginContext) => {
        if (!languagesCache) languagesCache = await helper.languages().catch(() => null);
        return {
          settings: { ...settings, deeplKey: settings.deeplKey ? "••••" + settings.deeplKey.slice(-4) : "" },
          languages: languagesCache || [], failedHotkeys: helper.failedHotkeys, live: live.on,
          ocrPacks: OCR_PACKS, ocrInstall,
          lastError, command: commandStatus(ctx)
        };
      },
      saveSettings: async (p: unknown) => {
        const patch = { ...(p && typeof p === "object" ? p : {}) } as Record<string, unknown>;
        if (typeof patch.deeplKey === "string" && patch.deeplKey.startsWith("••••")) delete patch.deeplKey;
        const before = [settings.hotkeyRegion, settings.hotkeyLive, settings.hotkeyWindow, settings.hotkeyWord].join();
        settings = cleanSettings({ ...settings, ...patch });
        save(SETTINGS, settings);
        if (before !== [settings.hotkeyRegion, settings.hotkeyLive, settings.hotkeyWindow, settings.hotkeyWord].join()) await applyHotkeys();
        await helper.setConfig({ enhance: settings.enhance });
        if (live.on && live.timer) { clearInterval(live.timer); live.timer = setInterval(() => void liveTick(), settings.liveMs); }
        await new Promise((r) => setTimeout(r, 300)); // помощник успеет ответить, какие клавиши заняты
        return { settings: { ...settings, deeplKey: settings.deeplKey ? "••••" + settings.deeplKey.slice(-4) : "" }, failedHotkeys: helper.failedHotkeys };
      },
      translateRegion: async () => background(translateRegion),
      toggleLive: async () => background(async () => (live.on ? stopLive() : startLive())),
      installOcr: async (p: unknown) => {
        if (ocrInstall.state === "running") return { started: false };
        const tag = String(param(p, "tag") || "");
        installCommand(tag); // проверка, что язык из списка
        return background(() => installOcrLanguage(tag));
      },
      createCommand: async (_p: unknown, ctx: PluginContext) => createCommand(ctx),
      testTranslate: async (p: unknown) => translate(String(param(p, "text") || "Press E to open the door."), settings.to, settings.engine, settings.deeplKey, settings.glossary)
    }
  },
  healthCheck: () => ({ healthy: true, status: lastError ? `ok (последняя ошибка: ${lastError})` : "ok" })
});

if (require.main === module) app.run();
