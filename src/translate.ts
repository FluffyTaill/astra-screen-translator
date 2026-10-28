// Translation services. Google's free endpoint needs no key; DeepL needs a (free) key.
// Results are cached: live subtitles ask for the same lines again and again.

export type Engine = "google" | "deepl";
export interface Translation { text: string; from: string; engine: Engine | "mymemory" }

const cache = new Map<string, Translation>();
const CACHE_MAX = 500;

function remember(key: string, t: Translation) {
  if (cache.size >= CACHE_MAX) cache.delete(cache.keys().next().value as string);
  cache.set(key, t);
  return t;
}

// Бесплатный Google иногда временно ограничивает частые запросы (HTTP 429). Тогда минуту перевод
// идёт через MyMemory (бесплатный официальный API, без ключа, но медленнее и попроще), а Google не
// трогаем, чтобы ограничение снялось
export class RateLimited extends Error {
  constructor() { super("Google временно ограничил запросы — подожди минуту или переключись на DeepL"); }
}
const GOOGLE_REST_MS = 60_000;
let googleRestUntil = 0;
export const googleResting = () => Date.now() < googleRestUntil;

// ── свой словарь ──
// «Stamina → Выносливость», «Geralt → (пусто: не переводить)». Термин в тексте заменяется меткой
// ZXQ<n>, которую переводчики оставляют как есть, а в переводе метка становится нужным словом.
export interface GlossaryRule { from: string; to: string }

const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

export function protect(text: string, rules: GlossaryRule[]) {
  const slots: string[] = [];
  let out = text;
  // длинные термины первыми: «Iron Sword» раньше «Sword»
  for (const r of [...rules].filter((x) => x.from.trim()).sort((a, b) => b.from.trim().length - a.from.trim().length)) {
    const term = r.from.trim();
    // целое слово, без учёта регистра; \p{L} — чтобы «Ice» не задел «Iceberg» и на кириллице тоже
    const re = new RegExp(`(?<![\\p{L}\\p{N}])${escapeRe(term)}(?![\\p{L}\\p{N}])`, "giu");
    out = out.replace(re, (m) => {
      slots.push(r.to.trim() || m);
      return `ZXQ${slots.length - 1}`;
    });
  }
  return { text: out, slots };
}

export function restore(text: string, slots: string[]) {
  if (!slots.length) return text;
  return text.replace(/ZXQ\s?(\d+)/gi, (m, n) => slots[Number(n)] ?? m);
}

export async function translate(text: string, to: string, engine: Engine, deeplKey = "", glossary: GlossaryRule[] = []): Promise<Translation> {
  const src = text.trim();
  if (!src) return { text: "", from: "", engine };
  const g = protect(src, glossary);
  const key = `${engine}|${to}|${g.text}|${g.slots.join("\u0001")}`;
  const hit = cache.get(key);
  if (hit) return hit;
  let t: Translation;
  if (engine === "deepl") {
    if (!deeplKey.trim()) throw new Error("Для DeepL нужен ключ — его можно получить бесплатно на deepl.com/pro-api");
    t = await deepl(g.text, to, deeplKey.trim());
  } else if (googleResting()) {
    t = await mymemory(g.text, to);
  } else {
    try {
      t = await google(g.text, to);
    } catch (e) {
      if (!(e instanceof RateLimited)) throw e;
      googleRestUntil = Date.now() + GOOGLE_REST_MS;
      t = await mymemory(g.text, to);
    }
  }
  return remember(key, { ...t, text: restore(t.text, g.slots) });
}

// ── словарная карточка для одного слова (Google: перевод, транскрипция, значения по частям речи) ──
export interface DictEntry { word: string; from: string; text: string; transcription: string; senses: { pos: string; words: string[] }[] }
const POS: Record<string, string> = {
  noun: "сущ.", verb: "глаг.", adjective: "прил.", adverb: "нареч.", pronoun: "мест.", preposition: "предл.",
  conjunction: "союз", interjection: "межд.", abbreviation: "сокр.", phrase: "фраза", prefix: "прист.", suffix: "суфф.",
  article: "артикль", particle: "част.", numeral: "числ."
};

export async function dictionary(word: string, to: string): Promise<DictEntry> {
  // Google ограничил запросы — хотя бы перевод слова, без значений и транскрипции
  const plain = async () => {
    const t = await mymemory(word, to);
    return { word, from: t.from, text: t.text, transcription: "", senses: [] };
  };
  if (googleResting()) return plain();
  try {
    return await googleDictionary(word, to);
  } catch (e) {
    if (!(e instanceof RateLimited)) throw e;
    googleRestUntil = Date.now() + GOOGLE_REST_MS;
    return plain();
  }
}

async function googleDictionary(word: string, to: string): Promise<DictEntry> {
  const url = `https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=${encodeURIComponent(to)}&dt=t&dt=bd&dt=rm&q=${encodeURIComponent(word)}`;
  const res = await fetch(url, { signal: AbortSignal.timeout(15000) });
  if (res.status === 429) throw new RateLimited();
  if (!res.ok) throw new Error(`Google Translate ответил ${res.status}`);
  const d = (await res.json()) as unknown[];
  const parts = (d[0] || []) as unknown[][];
  const text = parts.filter((p) => typeof p[0] === "string").map((p) => p[0]).join("");
  const rm = parts.find((p) => p[0] === null && p.length > 3);
  const senses = ((d[1] || []) as [string, string[]][]).map(([pos, words]) => ({ pos: POS[pos] || pos, words: (words || []).slice(0, 6) }));
  return { word, from: String(d[2] || ""), text, transcription: rm && typeof rm[3] === "string" ? rm[3] : "", senses };
}

// MyMemory: не больше ~500 символов за запрос, поэтому длинный текст — частями по предложениям.
// Без регистрации 5000 символов в день на этот компьютер
async function mymemory(text: string, to: string): Promise<Translation> {
  const parts: string[] = [];
  let cur = "";
  for (const s of text.split(/(?<=[.!?…])\s+|\r?\n/)) {
    if (cur && cur.length + s.length + 1 > 450) { parts.push(cur); cur = ""; }
    cur = cur ? `${cur} ${s}` : s;
    while (cur.length > 450) { parts.push(cur.slice(0, 450)); cur = cur.slice(450); }
  }
  if (cur) parts.push(cur);
  const out: string[] = [];
  let from = "";
  for (const q of parts) {
    const url = `https://api.mymemory.translated.net/get?q=${encodeURIComponent(q)}&langpair=${encodeURIComponent(`Autodetect|${to.split("-")[0]}`)}`;
    const res = await fetch(url, { signal: AbortSignal.timeout(20000) });
    if (!res.ok) throw new Error(`MyMemory ответил ${res.status}`);
    const d = (await res.json()) as { responseStatus: number | string; responseDetails?: string; quotaFinished?: boolean; responseData: { translatedText: string; detectedLanguage?: string } };
    if (d.quotaFinished || Number(d.responseStatus) === 429) throw new Error("Google ограничил запросы, а дневной лимит запасного переводчика MyMemory закончился — включи DeepL или подожди");
    if (Number(d.responseStatus) !== 200) throw new Error(`MyMemory: ${d.responseDetails || d.responseStatus}`);
    out.push(d.responseData.translatedText);
    from = from || String(d.responseData.detectedLanguage || "");
  }
  return { text: out.join(" "), from: from.split("-")[0], engine: "mymemory" };
}

// Google splits on its own; long requests go as a POST body, so a full screen of text fits
async function google(text: string, to: string): Promise<Translation> {
  const url = `https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=${encodeURIComponent(to)}&dt=t`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded;charset=UTF-8" },
    body: "q=" + encodeURIComponent(text),
    signal: AbortSignal.timeout(15000)
  });
  if (res.status === 429) throw new RateLimited();
  if (!res.ok) throw new Error(`Google Translate ответил ${res.status}`);
  const data = (await res.json()) as [Array<[string, string]>, unknown, string];
  return { text: (data[0] || []).map((p) => p[0]).join(""), from: String(data[2] || ""), engine: "google" };
}

async function deepl(text: string, to: string, key: string): Promise<Translation> {
  const host = key.endsWith(":fx") ? "https://api-free.deepl.com" : "https://api.deepl.com";
  const target = to.toUpperCase() === "EN" ? "EN-US" : to.toUpperCase() === "PT" ? "PT-BR" : to.toUpperCase();
  const res = await fetch(`${host}/v2/translate`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `DeepL-Auth-Key ${key}` },
    body: JSON.stringify({ text: [text], target_lang: target }),
    signal: AbortSignal.timeout(15000)
  });
  if (res.status === 403) throw new Error("DeepL не принял ключ");
  if (res.status === 456) throw new Error("DeepL: закончился месячный лимит символов");
  if (!res.ok) throw new Error(`DeepL ответил ${res.status}`);
  const data = (await res.json()) as { translations: { text: string; detected_source_language: string }[] };
  const t = data.translations[0];
  return { text: t.text, from: t.detected_source_language.toLowerCase(), engine: "deepl" };
}

// For live subtitles: is the newly read text really new, or the same line with OCR jitter?
export function normalize(s: string) {
  return s.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "");
}

export function similar(a: string, b: string): number {
  const x = normalize(a), y = normalize(b);
  if (x === y) return 1;
  if (!x || !y) return 0;
  if (Math.abs(x.length - y.length) > Math.max(x.length, y.length) * 0.3) return 0;
  // Levenshtein on short strings, else a cheap bigram overlap
  if (x.length * y.length <= 250_000) {
    let prev = Array.from({ length: y.length + 1 }, (_, i) => i);
    for (let i = 1; i <= x.length; i++) {
      const cur = [i];
      for (let j = 1; j <= y.length; j++) cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] === y[j - 1] ? 0 : 1));
      prev = cur;
    }
    return 1 - prev[y.length] / Math.max(x.length, y.length);
  }
  const grams = (s: string) => { const m = new Map<string, number>(); for (let i = 0; i < s.length - 1; i++) m.set(s.slice(i, i + 2), (m.get(s.slice(i, i + 2)) || 0) + 1); return m; };
  const gx = grams(x), gy = grams(y);
  let common = 0;
  for (const [g, n] of gx) common += Math.min(n, gy.get(g) || 0);
  return (2 * common) / (x.length + y.length - 2);
}

// Text in the target language already, or nothing worth translating (numbers, a single symbol)
export function worthTranslating(s: string) {
  return normalize(s).replace(/\d/g, "").length >= 2;
}
