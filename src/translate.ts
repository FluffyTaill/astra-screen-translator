// Translation services. Google's free endpoint needs no key; DeepL needs a (free) key.
// Results are cached: live subtitles ask for the same lines again and again.

export type Engine = "google" | "deepl";
export interface Translation { text: string; from: string; engine: Engine }

const cache = new Map<string, Translation>();
const CACHE_MAX = 500;

function remember(key: string, t: Translation) {
  if (cache.size >= CACHE_MAX) cache.delete(cache.keys().next().value as string);
  cache.set(key, t);
  return t;
}

export async function translate(text: string, to: string, engine: Engine, deeplKey = ""): Promise<Translation> {
  const src = text.trim();
  if (!src) return { text: "", from: "", engine };
  const key = `${engine}|${to}|${src}`;
  const hit = cache.get(key);
  if (hit) return hit;
  if (engine === "deepl") {
    if (!deeplKey.trim()) throw new Error("Для DeepL нужен ключ — его можно получить бесплатно на deepl.com/pro-api");
    return remember(key, await deepl(src, to, deeplKey.trim()));
  }
  return remember(key, await google(src, to));
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
