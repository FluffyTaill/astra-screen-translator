// Тесты в процессе: `pretest` собирает src/index.ts с внешним SDK. Сеть подменяется; помощник на
// PowerShell запускается только в отдельном тесте (настоящее распознавание Windows), без глобальных клавиш.
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { test } from "node:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

process.env.ST_NO_HELPER = "1";
const require = createRequire(import.meta.url);
const { app, cleanSettings, parseHotkey, DEFAULTS, Helper, similar, translate, worthTranslating, liveUpdate, speechChunks } = require("./.build/plugin.cjs");
const { Harness } = require("astra-plugin-sdk/testing");

const calls = [];
globalThis.fetch = async (url, init) => {
  const u = String(url);
  calls.push(u);
  if (u.includes("translate.googleapis.com")) {
    const q = decodeURIComponent(String(init.body).slice(2));
    return Response.json([[["Перевод: " + q, q]], null, "en"]);
  }
  if (u.includes("deepl.com")) {
    const auth = init.headers.authorization;
    if (auth.endsWith("bad")) return new Response("", { status: 403 });
    const body = JSON.parse(init.body);
    return Response.json({ translations: [{ text: `[${body.target_lang}] ${body.text[0]}`, detected_source_language: "EN" }] });
  }
  return new Response("nope", { status: 404 });
};

test("инструменты на месте, схемы проверяются", async () => {
  const h = await Harness.create(app).start();
  assert.deepEqual((await h.toolNames()).sort(), ["screen_subtitles", "screen_translate", "screen_translate_region"]);
  await h.assertSchemaAccepts("screen_translate", {});
  await h.assertSchemaAccepts("screen_translate", { target: "window", show: false });
  await h.assertSchemaRejects("screen_translate", { target: "desk" });
  await h.assertSchemaAccepts("screen_subtitles", { on: true });
  await h.assertSchemaRejects("screen_subtitles", {});
});

test("ни один конфиг от демона не роняет плагин", async () => {
  const h = await Harness.create(app).start();
  assert.deepEqual(await h.fuzzConfig(), []);
});

test("горячие клавиши разбираются, опасные отвергаются", () => {
  assert.deepEqual(parseHotkey("Ctrl+Alt+T"), { mods: 3, vk: 84 });
  assert.deepEqual(parseHotkey("ctrl + shift + 1"), { mods: 6, vk: 49 });
  assert.deepEqual(parseHotkey("F8"), { mods: 0, vk: 119 });
  assert.deepEqual(parseHotkey("Alt+`"), { mods: 1, vk: 192 });
  assert.deepEqual(parseHotkey("Win+Num5"), { mods: 8, vk: 101 });
  assert.equal(parseHotkey("T"), null, "буква без модификатора сломала бы набор текста");
  assert.equal(parseHotkey("Ctrl+Alt"), null);
  assert.equal(parseHotkey("Ctrl+Банан"), null);
});

test("настройки: мусор → значения по умолчанию, пустая клавиша — выключена", () => {
  assert.deepEqual(cleanSettings(null), DEFAULTS);
  const s = cleanSettings({ hotkeyRegion: "T", hotkeyLive: "", fontSize: 500, liveMs: 1, engine: "yandex", to: "../etc", ocrLang: "ja-JP", livePlace: "bottom", liveX: "abc", liveKeep: 99 });
  assert.equal(s.hotkeyRegion, DEFAULTS.hotkeyRegion);
  assert.equal(s.hotkeyLive, "");
  assert.equal(s.fontSize, 40);
  assert.equal(s.liveMs, 250);
  assert.equal(s.liveX, null);
  assert.equal(s.liveKeep, 6);
  assert.equal(cleanSettings({ livePlace: "custom", liveX: 640, liveY: 900 }).liveX, 640);
  assert.equal(s.engine, "google");
  assert.equal(s.to, "ru");
  assert.equal(s.ocrLang, "ja-JP");
  assert.equal(s.livePlace, "bottom");
});

test("перевод: Google без ключа, кэш, DeepL с ключом и понятными ошибками", async () => {
  const before = calls.length;
  const a = await translate("Press E", "ru", "google");
  assert.deepEqual(a, { text: "Перевод: Press E", from: "en", engine: "google" });
  await translate("Press E", "ru", "google");
  assert.equal(calls.length - before, 1, "второй раз — из кэша");
  assert.equal((await translate("Hello", "en", "deepl", "abc:fx")).text, "[EN-US] Hello");
  assert.match(calls.at(-1), /api-free\.deepl\.com/);
  await assert.rejects(translate("Hello", "ru", "deepl", ""), /нужен ключ/);
  await assert.rejects(translate("Hello2", "ru", "deepl", "bad"), /не принял ключ/);
  assert.deepEqual(await translate("   ", "ru", "google"), { text: "", from: "", engine: "google" });
});

test("субтитры: шум распознавания — не новый текст", () => {
  assert.equal(similar("Press E to open the door.", "Press E to open the door"), 1);
  assert.ok(similar("You shall not pass!", "You shal not pass!") > 0.85);
  assert.ok(similar("You shall not pass!", "Welcome to the village, traveler.") < 0.5);
  assert.equal(worthTranslating("12:45 / 100"), false);
  assert.equal(worthTranslating("—"), false);
  assert.equal(worthTranslating("Ok"), true);
});

test("субтитры: фразы копятся друг под другом, дописывание — на месте, мусор из кадра не проходит", () => {
  const st = { phrases: [], pending: new Map() };
  let now = 0;
  const step = (paras) => { now += 500; return liveUpdate(st, paras, now, 3000).map((f) => f.src); };
  assert.deepEqual(step(["Hello there, traveler!"]), [], "первое чтение — ждём подтверждения");
  assert.deepEqual(step(["Hello there, traveler!"]), ["Hello there, traveler!"], "второе — переводим");
  st.phrases[0].asked = st.phrases[0].src;
  assert.deepEqual(step(["Hello there, traveler!"]), [], "тот же текст — не переводим заново");
  // автосубтитры дописываются по слову — та же фраза растёт
  assert.deepEqual(step(["Hello there, traveler! Welcome"]), ["Hello there, traveler! Welcome"]);
  assert.equal(st.phrases.length, 1);
  st.phrases[0].asked = st.phrases[0].src;
  // быстро сменилась реплика: обе остаются в списке
  step(["Where is the blacksmith?"]);
  step(["Where is the blacksmith?"]);
  assert.equal(st.phrases.length, 2);
  // мусор мелькнул на одно чтение — не попал
  step(["Fish under the bridge"]);
  step(["Where is the blacksmith?"]);
  assert.deepEqual(st.phrases.map((f) => f.src), ["Hello there, traveler! Welcome", "Where is the blacksmith?"]);
  // через несколько секунд без фразы на экране она уходит
  for (let i = 0; i < 8; i++) step([]);
  assert.equal(st.phrases.length, 0);
});

test("для голоса — весь текст частями по предложениям, без потерь", () => {
  const sentence = "Первое предложение довольно длинное и подробное.";
  const long = Array(10).fill(sentence).join(" ");
  const parts = speechChunks(long);
  assert.ok(parts.length > 1);
  assert.ok(parts.every((p) => p.length <= 200));
  assert.equal(parts.join(" "), long, "ничего не пропало");
  assert.deepEqual(speechChunks("Коротко."), ["Коротко."]);
  const noDots = "слово ".repeat(80).trim();
  assert.equal(speechChunks(noDots).join(" "), noDots);
  assert.ok(speechChunks(noDots).every((p) => p.length <= 200));
});

test("помощник Windows: запускается, знает языки, распознаёт нарисованный текст", { skip: process.platform !== "win32", timeout: 60000 }, async () => {
  const h = new Helper(mkdtempSync(join(tmpdir(), "st-test-")));
  try {
    await h.start();
    const langs = await h.languages();
    assert.ok(langs.length >= 1);
    const tag = langs.find((l) => l.tag.startsWith("en"))?.tag || langs[0].tag;
    const r = await h.selfTest("Press E to open the door.", tag);
    assert.match(r.text, /open the door/i);
    // автоопределение: из всех языков Windows выбирается тот, чьё чтение похоже на слова
    const en = await h.selfTest("Welcome to the village, traveler!", "auto");
    assert.match(en.lang, /^en/);
    assert.match(en.text, /village/i);
    if (langs.some((l) => l.tag.startsWith("ru"))) {
      const ru = await h.selfTest("Сохранить игру? Да / Нет", "auto");
      assert.equal(ru.lang, "ru");
      assert.match(ru.text, /Сохранить игру/);
      // на экране два языка: каждая строка читается своим языком, мусор и короткие обрывки отброшены
      const mix = await h.selfTest(["is a class-three health code violation.", "Чтобы выйти из полноэкранного режима", "306 / 2504"].join(String.fromCharCode(10)), "auto");
      assert.match(mix.text, /class-three health code violation/);
      assert.match(mix.text, /Чтобы выйти из полноэкранного режима/);
      assert.doesNotMatch(mix.text, /2504|HT06|T06b/);
    }
  } finally {
    h.stop();
  }
});
