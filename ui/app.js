// Страница Screen Translator. Говорит с плагином через window.astra.callBackend(method, params).
const call = (m, p = {}) => window.astra.callBackend(m, p);
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const TARGETS = [["ru", "Русский"], ["en", "English"], ["uk", "Українська"], ["de", "Deutsch"], ["fr", "Français"], ["es", "Español"],
  ["it", "Italiano"], ["pl", "Polski"], ["pt", "Português"], ["tr", "Türkçe"], ["ja", "日本語"], ["zh-CN", "中文"], ["ko", "한국어"]];
let state = null;
let note = "";

function renderWarns() {
  const w = note ? [note] : [];
  if (state.failedHotkeys && state.failedHotkeys.length)
    w.push(`<div class="err">Эти сочетания заняты другой программой — выбери другие: ${state.failedHotkeys.map((id) => esc(state.settings[{ region: "hotkeyRegion", live: "hotkeyLive", window: "hotkeyWindow", word: "hotkeyWord" }[id]])).join(", ")}</div>`);
  if (!state.languages.length) w.push(`<div class="notice">Не удалось связаться с распознаванием Windows. Нужна Windows 10 или 11; попробуй перезапустить плагин.</div>`);
  if (state.lastError) w.push(`<div class="muted" style="margin-bottom:10px">Последняя ошибка: ${esc(state.lastError)}</div>`);
  $("warns").innerHTML = w.join("");
  $("toggleLive").textContent = state.live ? "Выключить субтитры" : "Субтитры";
  $("toggleLive").classList.toggle("on", state.live);
}

function renderSettings() {
  const s = state.settings;
  const langs = state.languages.length ? state.languages : (s.ocrLang === "auto" ? [] : [{ tag: s.ocrLang, name: s.ocrLang }]);
  const auto = `Автоматически${state.languages.length ? ` (${state.languages.map((l) => l.name.split(" ")[0]).join(", ")})` : ""}`;
  $("ocrLang").innerHTML = `<option value="auto">${esc(auto)}</option>` + langs.map((l) => `<option value="${esc(l.tag)}">${esc(l.name)}</option>`).join("");
  $("to").innerHTML = TARGETS.map(([v, n]) => `<option value="${v}">${n}</option>`).join("");
  document.querySelectorAll("[data-k]").forEach((el) => {
    const k = el.dataset.k;
    if (el.type === "checkbox") el.checked = !!s[k]; else el.value = s[k];
  });
  document.querySelectorAll("[data-hk]").forEach((el) => renderHotkey(el, s[el.dataset.hk]));
  $("deeplRow").style.display = s.engine === "deepl" ? "" : "none";
  renderGlossary();
  renderPacks();
  const c = state.command;
  $("speakNote").innerHTML = !s.speak ? "" : !c.inFile
    ? `<div class="notice" style="margin-top:10px">Чтобы Astra читала перевод, нужна команда. <button class="btn primary" id="mk">Создать команду</button> <span class="muted">Появится после перезапуска Astra.</span></div>`
    : !c.listening ? `<div class="notice" style="margin-top:10px">Команда создана — перезапусти Astra, чтобы она начала её слушать.</div>` : "";
  const mk = $("mk");
  if (mk) mk.onclick = async () => {
    try { const r = await call("createCommand"); note = `<div class="okbox">${r.added ? "Команда добавлена. Перезапусти Astra." : "Команда уже есть."}</div>`; }
    catch (e) { note = `<div class="err">${esc(e.message)}</div>`; }
    await refresh(true);
  };
}

async function refresh(all) {
  state = await call("getState");
  renderWarns();
  if (all) renderSettings(); else renderPacks();
}

// ── свой словарь ──
function renderGlossary() {
  const g = state.settings.glossary || [];
  $("glossary").innerHTML = g.length ? g.map((r, i) => `<div class="gl"><span class="gf">${esc(r.from)}</span><span class="muted">→</span><span class="gt">${r.to ? esc(r.to) : '<span class="muted">не переводить</span>'}</span><button class="btn" data-del="${i}" title="Удалить">✕</button></div>`).join("")
    : `<div class="muted">Пока пусто.</div>`;
  document.querySelectorAll("[data-del]").forEach((b) => {
    b.onclick = () => save({ glossary: g.filter((_, i) => i !== Number(b.dataset.del)) });
  });
}

function addRule() {
  const from = $("gFrom").value.trim();
  if (!from) return;
  const to = $("gTo").value.trim();
  const g = (state.settings.glossary || []).filter((r) => r.from.toLowerCase() !== from.toLowerCase());
  $("gFrom").value = ""; $("gTo").value = "";
  save({ glossary: [...g, { from, to }] });
}

// ── языки распознавания ──
function renderPacks() {
  if (!state.ocrPacks) return;
  const have = state.languages.map((l) => l.tag.toLowerCase());
  const has = (tag) => have.some((h) => h === tag.toLowerCase() || h === tag.split("-")[0].toLowerCase() || h.split("-")[0] === tag.split("-")[0].toLowerCase());
  $("haveLangs").textContent = state.languages.map((l) => l.name).join(", ") || "—";
  const sel = $("packSel");
  const keep = sel.value;
  const missing = state.ocrPacks.filter((p) => !has(p.tag));
  if (sel.dataset.sig !== missing.map((p) => p.tag).join()) {
    sel.dataset.sig = missing.map((p) => p.tag).join();
    sel.innerHTML = missing.length ? missing.map((p) => `<option value="${p.tag}">${esc(p.name)}</option>`).join("") : `<option value="">все из списка уже есть</option>`;
    if (missing.some((p) => p.tag === keep)) sel.value = keep;
  }
  const st = state.ocrInstall;
  const running = st.state === "running";
  $("packAdd").disabled = running || !missing.length;
  $("packAdd").textContent = running ? "Устанавливаю…" : "Установить";
  if (st.state !== "idle") $("packNote").innerHTML = `<span class="${st.state === "error" ? "bad" : st.state === "done" ? "good" : ""}">${esc(st.message)}</span>`;
}

async function save(patch) {
  const r = await call("saveSettings", patch);
  state.settings = r.settings;
  state.failedHotkeys = r.failedHotkeys;
  renderSettings();
  renderWarns();
}

// Сочетание собирается кнопками и списком, без нажатия клавиш: внутри Astra страница их не
// получает, а Ctrl+A и подобные выделяли всю страницу
const MOD_NAMES = ["Ctrl", "Alt", "Shift", "Win"];
const KEY_LIST = [
  ...[..."ABCDEFGHIJKLMNOPQRSTUVWXYZ"], ...[..."0123456789"],
  ...Array.from({ length: 12 }, (_, i) => `F${i + 1}`),
  "Space", "`", "Insert", "Delete", "Home", "End", "PageUp", "PageDown", "Pause", "PrintScreen",
  "Up", "Down", "Left", "Right", ...Array.from({ length: 10 }, (_, i) => `Num${i}`)
];
const HK_ID = { hotkeyRegion: "region", hotkeyLive: "live", hotkeyWindow: "window", hotkeyWord: "word" };

function splitCombo(value) {
  const parts = (value || "").split("+").map((p) => p.trim()).filter(Boolean);
  const mods = parts.filter((p) => MOD_NAMES.some((m) => m.toLowerCase() === p.toLowerCase())).map((p) => MOD_NAMES.find((m) => m.toLowerCase() === p.toLowerCase()));
  const key = parts.find((p) => !mods.some((m) => m.toLowerCase() === p.toLowerCase())) || "";
  return { mods, key: KEY_LIST.find((k) => k.toLowerCase() === key.toLowerCase()) || key.toUpperCase() };
}

function renderHotkey(el, value) {
  const { mods, key } = splitCombo(value);
  const off = !key;
  el.classList.toggle("bad", (state.failedHotkeys || []).includes(HK_ID[el.dataset.hk]));
  el.innerHTML = MOD_NAMES.map((m) => `<button class="mod${mods.includes(m) ? " on" : ""}" data-mod="${m}"${off ? " disabled" : ""}>${m}</button>`).join("") +
    `<select><option value="">выкл</option>${KEY_LIST.map((k) => `<option value="${esc(k)}"${k === key ? " selected" : ""}>${esc(k)}</option>`).join("")}</select>`;
  const commit = (nextMods, nextKey) => {
    if (!nextKey) return save({ [el.dataset.hk]: "" });
    // буква или цифра без Ctrl/Alt/Win сломала бы обычный набор текста
    if (/^[A-Z0-9]$/.test(nextKey) && !nextMods.some((m) => m !== "Shift")) {
      nextMods = ["Ctrl", "Alt", ...nextMods.filter((m) => m === "Shift")];
      note = `<div class="notice">Буква без Ctrl/Alt мешала бы печатать — добавила Ctrl+Alt.</div>`;
    }
    save({ [el.dataset.hk]: [...MOD_NAMES.filter((m) => nextMods.includes(m)), nextKey].join("+") });
  };
  el.querySelectorAll("[data-mod]").forEach((b) => {
    b.onclick = () => {
      const m = b.dataset.mod;
      commit(mods.includes(m) ? mods.filter((x) => x !== m) : [...mods, m], key);
    };
  });
  el.querySelector("select").onchange = (e) => commit(mods.length || !e.target.value ? mods : ["Ctrl", "Alt"], e.target.value);
}

(async () => {
  try {
    await refresh(true);
  } catch (e) {
    $("warns").innerHTML = `<div class="err">${esc(e.message)}</div>`;
    return;
  }
  document.querySelectorAll("[data-k]").forEach((el) => {
    el.onchange = () => save({ [el.dataset.k]: el.type === "checkbox" ? el.checked : el.type === "number" ? Number(el.value) : el.value });
  });
  $("gAdd").onclick = addRule;
  $("gTo").onkeydown = (e) => { if (e.key === "Enter") addRule(); };
  $("packAdd").onclick = async () => {
    const tag = $("packSel").value;
    if (!tag) return;
    $("packAdd").disabled = true;
    try { await call("installOcr", { tag }); } catch (e) { $("packNote").textContent = e.message; }
    refresh(false);
  };
  $("tryRegion").onclick = () => call("translateRegion").catch(() => {});
  $("toggleLive").onclick = async () => { await call("toggleLive").catch(() => {}); setTimeout(() => refresh(false), 600); };
  setInterval(() => refresh(false).catch(() => {}), 3000);
})();
