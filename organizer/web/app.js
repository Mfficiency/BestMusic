"use strict";
// Best Music Organizer - the page. Everything runs against the local server (mo/server.py);
// the whole library is held in memory here, so filtering, sorting and grouping are instant.

// ------------------------------------------------------------------ helpers
const $ = (sel, el = document) => el.querySelector(sel);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const h = (html) => { const t = document.createElement("template"); t.innerHTML = html.trim(); return t.content.firstElementChild; };
const plural = (n, w) => `${n} ${w}${n === 1 ? "" : "s"}`;
const mb = (b) => b > 1 << 30 ? (b / (1 << 30)).toFixed(1) + " GB" : Math.round(b / (1 << 20)) + " MB";
const dur = (s) => s ? `${Math.floor(s / 60)}:${String(Math.round(s % 60)).padStart(2, "0")}` : "";
const norm = (s) => String(s || "").normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase();

async function api(path, body) {
  const opt = body === undefined ? {} : { method: "POST", headers: { "Content-Type": "application/json", "X-Organizer": "1" }, body: JSON.stringify(body) };
  const r = await fetch(path, opt);
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error || r.statusText);
  return data;
}

function toast(msg, ms = 2600) {
  const t = $("#toast");
  t.textContent = msg;
  t.classList.add("show");
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => t.classList.remove("show"), ms);
}

// Waits for a background job; onUpdate(job) on every poll. Resolves with job.result.
async function waitJob(job, onUpdate) {
  for (;;) {
    if (job.status !== "running") break;
    await new Promise((r) => setTimeout(r, 400));
    job = await api(`/api/job?id=${job.id}`);
    onUpdate && onUpdate(job);
    pollJobs.kick();
  }
  if (job.status === "error") throw new Error(job.error);
  return job.result;
}

async function runAndReload(promise, done) {
  try {
    const job = await promise;
    const res = await waitJob(job);
    await loadLibrary();
    if (res && res.failed && res.failed.length) toast(`${res.done} done, ${res.failed.length} failed: ${res.failed[0].error}`, 6000);
    else if (done) toast(done(res));
    return res;
  } catch (e) { toast(e.message, 6000); }
}

// ------------------------------------------------------------------ state
const S = {
  tracks: [], byPath: new Map(), version: -1, playlists: [], state: null,
  view: "songs", selected: new Set(), playing: null,
};

async function loadState() {
  S.state = await api("/api/state");
  $("#count-pending").textContent = S.state.pending ? S.state.pending : "";
  return S.state;
}

async function loadLibrary(force) {
  await loadState();
  if (!force && S.state.version === S.version && S.tracks.length) return;
  if (!S.state.musicOk) { S.tracks = []; S.byPath = new Map(); render(); return; }
  const data = await api("/api/tracks");
  const f = data.fields;
  S.tracks = data.rows.map((r) => {
    const t = {};
    f.forEach((k, i) => (t[k] = r[i]));
    t.folder = t.path.includes("/") ? t.path.slice(0, t.path.lastIndexOf("/")) : "";
    t.stem = t.path.slice(t.path.lastIndexOf("/") + 1).replace(/\.[^.]+$/, "");
    t.hay = norm([t.title, t.artist, t.album, t.genre, t.path, t.year].join(" "));
    return t;
  });
  S.byPath = new Map(S.tracks.map((t) => [t.path, t]));
  S.version = data.version;
  $("#count-songs").textContent = S.tracks.length || "";
  for (const p of [...S.selected]) if (!S.byPath.has(p)) S.selected.delete(p);
  await loadPlaylists();
  render();
}

async function loadPlaylists() {
  S.playlists = S.state && S.state.musicOk ? await api("/api/playlists") : [];
  const box = $("#playlist-links");
  box.innerHTML = "";
  for (const p of S.playlists) {
    const a = h(`<a href="#playlist/${encodeURIComponent(p.path)}" data-view="playlist/${esc(p.path)}">${esc(p.name)} <span class="count">${p.tracks.length}</span></a>`);
    a.addEventListener("dragover", (e) => { e.preventDefault(); a.classList.add("drop"); });
    a.addEventListener("dragleave", () => a.classList.remove("drop"));
    a.addEventListener("drop", async (e) => {
      e.preventDefault();
      a.classList.remove("drop");
      const paths = JSON.parse(e.dataTransfer.getData("text/x-songs") || "[]");
      if (paths.length) await addToPlaylist(p.path, paths);
    });
    box.appendChild(a);
  }
  markNav();
}

async function addToPlaylist(path, paths, name) {
  try {
    const r = await api("/api/playlist/add", { path, name, tracks: paths });
    await loadLibrary(true);
    toast(`${plural(paths.length, "song")} added (${r.count} in the playlist)`);
  } catch (e) { toast(e.message, 5000); }
}

// ------------------------------------------------------------------ song table
const COLS = [
  { key: "title", label: "Title", w: "minmax(160px,2.2fr)", get: (t) => t.title || t.stem },
  { key: "artist", label: "Artist", w: "minmax(110px,1.4fr)" },
  { key: "album", label: "Album", w: "minmax(90px,1.2fr)" },
  { key: "genre", label: "Genre", w: "minmax(70px,.8fr)" },
  { key: "year", label: "Year", w: "54px", num: true },
  { key: "duration", label: "Time", w: "52px", num: true, fmt: dur, edit: false },
  { key: "folder", label: "Folder", w: "minmax(90px,1.2fr)", faint: true, edit: false },
];
const EDITABLE = ["title", "artist", "album", "albumartist", "genre", "year", "track"];

// A virtual list of songs: only the visible rows exist in the page.
class SongTable {
  constructor(el, opts = {}) {
    this.el = el;
    this.opts = opts; // {ordered: bool (playlist order), onReorder(paths), emptyText}
    this.rows = [];
    this.sort = opts.ordered ? null : { key: "artist", dir: 1 };
    this.filter = "";
    this.anchor = null;
    el.classList.add("table");
    el.style.setProperty("--cols", COLS.map((c) => c.w).join(" "));
    el.innerHTML = `<div class="thead">${COLS.map((c) => `<div data-k="${c.key}">${c.label}</div>`).join("")}</div><div class="tbody" tabindex="0"><div class="spacer"></div></div>`;
    this.body = $(".tbody", el);
    this.spacer = $(".spacer", el);
    $(".thead", el).addEventListener("click", (e) => {
      const k = e.target.dataset.k;
      if (!k) return;
      this.sort = this.sort && this.sort.key === k ? { key: k, dir: -this.sort.dir } : { key: k, dir: 1 };
      this.refresh();
    });
    this.body.addEventListener("scroll", () => this.paint());
    this.body.addEventListener("mousedown", (e) => this.click(e));
    this.body.addEventListener("mouseup", (e) => this.release(e));
    this.body.addEventListener("dblclick", (e) => this.dbl(e));
    this.body.addEventListener("keydown", (e) => this.key(e));
    this.body.addEventListener("dragstart", (e) => this.dragstart(e));
    if (opts.ordered) {
      this.body.addEventListener("dragover", (e) => e.preventDefault());
      this.body.addEventListener("drop", (e) => this.drop(e));
    }
    new ResizeObserver(() => this.paint()).observe(this.body);
  }

  set(tracks) { this.source = tracks; this.refresh(); }
  setFilter(q) { this.filter = norm(q).trim(); this.refresh(); }

  refresh() {
    const words = this.filter.split(/\s+/).filter(Boolean);
    let rows = words.length ? this.source.filter((t) => words.every((w) => t.hay.includes(w))) : this.source.slice();
    if (this.sort) {
      const { key, dir } = this.sort;
      const col = COLS.find((c) => c.key === key) || {};
      const val = (t) => (col.get ? col.get(t) : t[key]);
      const second = (t) => `${norm(t.artist)}\u0000${t.album || ""}\u0000${String(t.track || 0).padStart(3, "0")}\u0000${norm(t.title || t.stem)}`;
      rows.sort((a, b) => {
        const x = val(a), y = val(b);
        let c = col.num ? (x || 0) - (y || 0) : norm(x).localeCompare(norm(y));
        if (!c) c = second(a).localeCompare(second(b));
        return c * dir;
      });
    }
    this.rows = rows;
    $(".thead", this.el).querySelectorAll("div").forEach((d) => {
      const on = this.sort && d.dataset.k === this.sort.key;
      d.classList.toggle("sorted", !!on);
      const c = COLS.find((c) => c.key === d.dataset.k);
      d.textContent = c.label + (on ? (this.sort.dir > 0 ? " ▲" : " ▼") : "");
    });
    this.spacer.style.height = rows.length * 30 + "px";
    this.paint(true);
    this.opts.onChange && this.opts.onChange(this);
  }

  paint(force) {
    const top = this.body.scrollTop, height = this.body.clientHeight || 600;
    const first = Math.max(0, Math.floor(top / 30) - 10), last = Math.min(this.rows.length, Math.ceil((top + height) / 30) + 10);
    if (!force && this.painted && this.painted[0] === first && this.painted[1] === last) return;
    this.painted = [first, last];
    for (const r of [...this.body.querySelectorAll(".trow")]) r.remove();
    if (!this.rows.length) {
      if (!$(".empty", this.body)) this.body.appendChild(h(`<div class="empty">${esc(this.opts.emptyText || "No songs here")}</div>`));
      return;
    }
    $(".empty", this.body)?.remove();
    const frag = document.createDocumentFragment();
    for (let i = first; i < last; i++) {
      const t = this.rows[i];
      const row = document.createElement("div");
      row.className = "trow" + (S.selected.has(t.path) ? " sel" : "") + (S.playing === t.path ? " playing" : "");
      row.style.top = i * 30 + "px";
      row.dataset.i = i;
      row.draggable = true;
      row.innerHTML = COLS.map((c) => {
        const v = c.get ? c.get(t) : t[c.key];
        return `<div class="c-${c.key}${c.num ? " num" : ""}${c.faint ? " faint" : ""}" title="${esc(c.key === "title" ? t.path : v)}">${esc(c.fmt ? c.fmt(v) : v ?? "")}</div>`;
      }).join("");
      frag.appendChild(row);
    }
    this.body.appendChild(frag);
  }

  rowAt(e) { const r = e.target.closest(".trow"); return r ? +r.dataset.i : -1; }

  click(e) {
    if (e.target.tagName === "INPUT") return;
    const i = this.rowAt(e);
    if (i < 0) { if (!e.ctrlKey && !e.metaKey) { S.selected.clear(); this.paint(true); updateSelbar(); } return; }
    const p = this.rows[i].path;
    if (e.shiftKey && this.anchor !== null) {
      const [a, b] = [Math.min(this.anchor, i), Math.max(this.anchor, i)];
      if (!e.ctrlKey && !e.metaKey) S.selected.clear();
      for (let k = a; k <= b; k++) S.selected.add(this.rows[k].path);
    } else if (e.ctrlKey || e.metaKey) {
      S.selected.has(p) ? S.selected.delete(p) : S.selected.add(p);
      this.anchor = i;
    } else if (!S.selected.has(p)) {
      S.selected.clear();
      S.selected.add(p);
      this.anchor = i;
    } else {
      this.pending = i; // one of several selected: narrow on mouseup unless it becomes a drag
      return;
    }
    this.paint(true);
    updateSelbar();
  }

  release(e) {
    const i = this.pending;
    this.pending = null;
    if (i === null || i === undefined || i !== this.rowAt(e)) return;
    S.selected.clear();
    S.selected.add(this.rows[i].path);
    this.anchor = i;
    this.paint(true);
    updateSelbar();
  }

  dbl(e) {
    const i = this.rowAt(e);
    if (i < 0) return;
    const cell = e.target.closest("div[class^='c-']");
    const key = cell && cell.className.match(/c-(\w+)/)[1];
    const col = COLS.find((c) => c.key === key);
    if (col && col.edit !== false && EDITABLE.includes(key) && !e.altKey) return this.inlineEdit(cell, this.rows[i], key);
    play(this.rows, i);
  }

  inlineEdit(cell, t, key) {
    const input = h(`<input class="cell" type="text">`);
    input.value = t[key] ?? "";
    cell.textContent = "";
    cell.appendChild(input);
    input.focus();
    input.select();
    let done = false;
    const finish = async (save) => {
      if (done) return;
      done = true;
      const v = input.value.trim();
      if (save && v !== String(t[key] ?? "")) {
        const paths = S.selected.has(t.path) && S.selected.size > 1 ? [...S.selected] : [t.path];
        await runAndReload(api("/api/tags", { paths, fields: { [key]: v } }), () => `${key} set on ${plural(paths.length, "song")}`);
      } else this.paint(true);
    };
    input.addEventListener("keydown", (e) => {
      e.stopPropagation();
      if (e.key === "Enter") finish(true);
      if (e.key === "Escape") finish(false);
    });
    input.addEventListener("blur", () => finish(true));
  }

  key(e) {
    if (e.target.tagName === "INPUT") return;
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "a") {
      e.preventDefault();
      this.rows.forEach((t) => S.selected.add(t.path));
      this.paint(true);
      updateSelbar();
    } else if (e.key === "Delete" && S.selected.size) {
      actions.remove();
    } else if (e.key === "Enter" && S.selected.size) {
      const i = this.rows.findIndex((t) => S.selected.has(t.path));
      if (i >= 0) play(this.rows, i);
    } else if (e.key === "F2" && S.selected.size) {
      actions.edit();
    } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      const cur = this.rows.findIndex((t) => S.selected.has(t.path));
      const i = Math.max(0, Math.min(this.rows.length - 1, cur + (e.key === "ArrowDown" ? 1 : -1)));
      if (!this.rows[i]) return;
      if (!e.shiftKey) S.selected.clear();
      S.selected.add(this.rows[i].path);
      this.anchor = i;
      const y = i * 30;
      if (y < this.body.scrollTop) this.body.scrollTop = y;
      if (y + 30 > this.body.scrollTop + this.body.clientHeight) this.body.scrollTop = y + 30 - this.body.clientHeight;
      this.paint(true);
      updateSelbar();
    }
  }

  dragstart(e) {
    this.pending = null;
    const i = this.rowAt(e);
    if (i < 0) return;
    if (!S.selected.has(this.rows[i].path)) { S.selected.clear(); S.selected.add(this.rows[i].path); this.paint(true); updateSelbar(); }
    const paths = this.rows.filter((t) => S.selected.has(t.path)).map((t) => t.path);
    e.dataTransfer.setData("text/x-songs", JSON.stringify(paths));
    e.dataTransfer.effectAllowed = "copyMove";
  }

  drop(e) {
    e.preventDefault();
    const moving = JSON.parse(e.dataTransfer.getData("text/x-songs") || "[]");
    if (!moving.length) return;
    const y = e.clientY - this.body.getBoundingClientRect().top + this.body.scrollTop;
    const at = Math.max(0, Math.min(this.rows.length, Math.round(y / 30)));
    const before = this.rows.slice(0, at).filter((t) => !moving.includes(t.path));
    const after = this.rows.slice(at).filter((t) => !moving.includes(t.path));
    const order = [...before.map((t) => t.path), ...moving, ...after.map((t) => t.path)];
    this.opts.onReorder && this.opts.onReorder(order);
  }
}

function selectedPaths() { return [...S.selected].filter((p) => S.byPath.has(p)); }

// The action bar shown while songs are selected.
function selbar(extra = "") {
  return `<div class="selbar" hidden><b class="selcount"></b>
    <button data-a="play">Play</button><button data-a="edit">Edit info…</button>
    <button data-a="playlist">Add to playlist…</button><button data-a="move">Move to folder…</button>
    <button data-a="rename">Rename by pattern…</button><button data-a="clean">Clean up names</button>
    ${extra}<button data-a="remove" class="danger">Delete</button><span class="grow"></span>
    <button data-a="none">Select none</button></div>`;
}

function updateSelbar() {
  const bar = $(".selbar");
  if (!bar) return;
  const n = selectedPaths().length;
  bar.hidden = !n;
  $(".selcount", bar).textContent = plural(n, "song") + " selected";
}

function wireSelbar(root, table) {
  const bar = $(".selbar", root);
  if (!bar) return;
  bar.addEventListener("click", (e) => {
    const a = e.target.dataset.a;
    if (!a) return;
    if (a === "none") { S.selected.clear(); table.paint(true); updateSelbar(); return; }
    if (a === "play") { const rows = table.rows.filter((t) => S.selected.has(t.path)); return play(rows, 0); }
    actions[a] && actions[a](table);
  });
  updateSelbar();
}

const actions = {
  edit() { editTags(selectedPaths()); },
  playlist() { pickPlaylist(selectedPaths()); },
  move() { moveToFolder(selectedPaths()); },
  rename() { renameByPattern(selectedPaths()); },
  clean() { location.hash = "#tidy/names"; S.cleanOnly = new Set(selectedPaths()); },
  async remove() {
    const paths = selectedPaths();
    if (!paths.length || !confirm(`Delete ${plural(paths.length, "song")}? They go to the organizer's trash here, and to the Pi's trash at the next sync.`)) return;
    await runAndReload(api("/api/delete", { paths }), (r) => `Deleted ${plural(r.done, "song")}`);
    S.selected.clear();
  },
};

// ------------------------------------------------------------------ modals
function modal(html, onOk) {
  const back = h(`<div class="back"><div class="modal">${html}</div></div>`);
  $("#modal-root").appendChild(back);
  const close = () => back.remove();
  back.addEventListener("mousedown", (e) => { if (e.target === back) close(); });
  back.addEventListener("keydown", (e) => {
    if (e.key === "Escape") close();
    if (e.key === "Enter" && e.target.tagName === "INPUT") { e.preventDefault(); $(".ok", back)?.click(); }
  });
  back.querySelectorAll("[data-close]").forEach((b) => b.addEventListener("click", close));
  const ok = $(".ok", back);
  if (ok) ok.addEventListener("click", async () => { ok.disabled = true; if ((await onOk(back)) !== false) close(); else ok.disabled = false; });
  setTimeout(() => back.querySelector("input,select,textarea")?.focus(), 0);
  return back;
}

function datalists() {
  const uniq = (k) => [...new Set(S.tracks.map((t) => t[k]).filter(Boolean))].sort((a, b) => a.localeCompare(b));
  return ["artist", "album", "genre"].map((k) => `<datalist id="dl-${k}">${uniq(k).slice(0, 3000).map((v) => `<option value="${esc(v)}">`).join("")}</datalist>`).join("")
    + `<datalist id="dl-albumartist">${uniq("artist").slice(0, 3000).map((v) => `<option value="${esc(v)}">`).join("")}</datalist>`;
}

function editTags(paths) {
  if (!paths.length) return;
  const ts = paths.map((p) => S.byPath.get(p));
  const same = (k) => { const v = ts[0][k] ?? ""; return ts.every((t) => (t[k] ?? "") === v) ? v : null; };
  const labels = { title: "Title", artist: "Artist", album: "Album", albumartist: "Album artist", genre: "Genre", year: "Year", track: "Track #" };
  const rows = EDITABLE.filter((k) => !(paths.length > 1 && (k === "title" || k === "track"))).map((k) => {
    const v = same(k);
    return `<label>${labels[k]}</label><input type="text" name="${k}" list="dl-${k}" value="${esc(v ?? "")}" placeholder="${v === null ? "(different values: unchanged)" : ""}" data-orig="${esc(v ?? "")}" data-mixed="${v === null}">`;
  }).join("");
  modal(`<h2>Edit info · ${plural(paths.length, "song")}</h2><div class="field">${rows}</div>${datalists()}
    <p class="sub">Changes are written into the files' tags.</p>
    <div class="actions"><button data-close>Cancel</button><button class="primary ok">Save</button></div>`, async (m) => {
    const fields = {};
    m.querySelectorAll("input[name]").forEach((i) => {
      if (i.dataset.mixed === "true" ? i.value !== "" : i.value !== i.dataset.orig) fields[i.name] = i.value;
    });
    if (!Object.keys(fields).length) return;
    await runAndReload(api("/api/tags", { paths, fields }), () => `Saved ${plural(paths.length, "song")}`);
  });
}

function pickPlaylist(paths) {
  if (!paths.length) return;
  const opts = S.playlists.map((p) => `<option value="${esc(p.path)}">${esc(p.name)} (${p.tracks.length})</option>`).join("");
  modal(`<h2>Add ${plural(paths.length, "song")} to a playlist</h2>
    <div class="field"><label>Playlist</label><select name="pl"><option value="">New playlist…</option>${opts}</select>
    <label>New name</label><input type="text" name="name" placeholder="e.g. Summer 2026"></div>
    <div class="actions"><button data-close>Cancel</button><button class="primary ok">Add</button></div>`, async (m) => {
    const path = $("select", m).value, name = $("input[name=name]", m).value.trim();
    if (!path && !name) { toast("Give the new playlist a name"); return false; }
    await addToPlaylist(path || null, paths, name);
  });
}

async function moveToFolder(paths) {
  if (!paths.length) return;
  const folders = await api("/api/folders");
  modal(`<h2>Move ${plural(paths.length, "song")} to a folder</h2>
    <div class="field"><label>Folder</label><input type="text" name="folder" list="dl-folders" placeholder="e.g. Chill or Party/2026">
    <span class="hint">Pick one or type a new one. Empty = the top of the music folder.</span></div>
    <datalist id="dl-folders">${folders.map((f) => `<option value="${esc(f)}">`).join("")}</datalist>
    <div class="actions"><button data-close>Cancel</button><button class="primary ok">Move</button></div>`, async (m) => {
    const folder = $("input", m).value.trim().replace(/^\/+|\/+$/g, "");
    await runAndReload(api("/api/move", { paths, folder }), (r) => `Moved ${plural(r.done, "song")}`);
  });
}

function patternSelect(value) {
  const presets = S.state.presets;
  return `<select class="preset">${Object.entries(presets).map(([p, l]) => `<option value="${esc(p)}"${p === value ? " selected" : ""}>${esc(l)}</option>`).join("")}<option value="">Custom…</option></select>
    <input type="text" class="pattern mono" value="${esc(value)}" size="38">`;
}

function wirePattern(root) {
  const sel = $(".preset", root), input = $(".pattern", root);
  sel.addEventListener("change", () => { if (sel.value) input.value = sel.value; input.dispatchEvent(new Event("input")); });
}

const PATTERN_HELP = `Fields: {artist} {albumartist} {title} {album} {genre} {year} {track} {first} (first letter). "/" makes folders.`;

async function renameByPattern(paths) {
  if (!paths.length) return;
  const m = modal(`<h2>Rename ${plural(paths.length, "song")} by pattern</h2>
    <div class="form-row">${patternSelect(S.state.config.pattern)}</div><p class="sub">${PATTERN_HELP}</p>
    <div class="scroll"><table class="list"><thead><tr><th>Now</th><th>Becomes</th></tr></thead><tbody class="pv"></tbody></table></div>
    <div class="actions"><button data-close>Cancel</button><button class="primary ok">Rename</button></div>`, async (m) => {
    const pattern = $(".pattern", m).value.trim();
    await runAndReload(api("/api/move", { paths, pattern }), (r) => `Renamed ${plural(r.done, "song")}`);
  });
  wirePattern(m);
  const preview = async () => {
    const moves = await api("/api/organize/preview", { pattern: $(".pattern", m).value, paths });
    $(".pv", m).innerHTML = moves.length ? moves.slice(0, 300).map((x) => `<tr><td class="mono old">${esc(x.from)}</td><td class="mono new">${esc(x.to)}</td></tr>`).join("")
      : `<tr><td colspan="2" class="sub">Already named like this.</td></tr>`;
  };
  $(".pattern", m).addEventListener("input", debounce(preview, 250));
  preview();
}

function debounce(fn, ms) { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; }

// ------------------------------------------------------------------ player
function play(rows, i) {
  S.queue = rows.map((t) => t.path);
  S.qi = i;
  playCurrent();
}

function playCurrent() {
  const p = S.queue && S.queue[S.qi];
  if (!p) return;
  const t = S.byPath.get(p);
  const audio = $("#audio");
  audio.src = `/api/audio?path=${encodeURIComponent(p)}`;
  audio.play().catch((e) => toast("Can't play this file here: " + e.message));
  S.playing = p;
  $("#player").classList.add("playing");
  $("#now").textContent = t ? `${t.title || t.stem} — ${t.artist || "Unknown artist"}` : p;
  document.querySelectorAll(".tbody").forEach((b) => b.dispatchEvent(new Event("scroll")));
  S.table && S.table.paint(true);
}

function initPlayer() {
  const audio = $("#audio");
  audio.controls = true;
  audio.addEventListener("ended", () => { if (S.queue && S.qi < S.queue.length - 1) { S.qi++; playCurrent(); } });
  audio.addEventListener("play", () => ($("#play-toggle").textContent = "❚❚"));
  audio.addEventListener("pause", () => ($("#play-toggle").textContent = "▶"));
  $("#play-toggle").addEventListener("click", () => (audio.src ? (audio.paused ? audio.play() : audio.pause()) : null));
  document.addEventListener("keydown", (e) => {
    if (e.key === " " && !["INPUT", "TEXTAREA", "SELECT", "BUTTON"].includes(e.target.tagName) && audio.src) {
      e.preventDefault();
      audio.paused ? audio.play() : audio.pause();
    }
    if (e.key === "/" && !["INPUT", "TEXTAREA"].includes(e.target.tagName)) {
      const f = $("#main input[type=search]");
      if (f) { e.preventDefault(); f.focus(); }
    }
  });
}

// ------------------------------------------------------------------ views
const views = {};

function noLibrary(main) {
  main.innerHTML = `<div class="pad"><h1>Welcome</h1><p>Pick the folder with your music first: <a href="#settings">Settings</a>.</p></div>`;
}

function songView(main, { title, tracks, extraBar = "", sub = "", ordered = false, onReorder, emptyText, head = "" }) {
  main.innerHTML = `<header class="bar"><h1>${esc(title)}</h1><span class="sub">${sub}</span><span class="grow"></span>${head}
    <input type="search" class="filter" placeholder="Filter (press /)" size="28"></header>${selbar(extraBar)}<div class="songs"></div>`;
  const table = new SongTable($(".songs", main), { ordered, onReorder, emptyText,
    onChange: (tb) => { const s = $("header .sub", main); if (s && !sub) s.textContent = tb.filter ? `${tb.rows.length} of ${tb.source.length}` : plural(tb.source.length, "song"); } });
  S.table = table;
  table.set(tracks);
  const f = $(".filter", main);
  f.value = S.filterText || "";
  if (f.value) table.setFilter(f.value);
  f.addEventListener("input", debounce(() => { S.filterText = f.value; table.setFilter(f.value); }, 80));
  wireSelbar(main, table);
  return table;
}

views.songs = (main) => {
  if (!S.state.musicOk) return noLibrary(main);
  songView(main, { title: "Songs", tracks: S.tracks, head: `<button class="rescan">Rescan</button>`, emptyText: "No songs yet - add some to your music folder or use Get music." });
  $(".rescan", main).addEventListener("click", () => runAndReload(api("/api/scan", {}), (r) => `${plural(r.files, "file")}, ${r.read} read again`));
};

function groupView(main, field, label) {
  if (!S.state.musicOk) return noLibrary(main);
  const groups = new Map();
  const keyOf = (t) => (field === "album" ? (t.album ? `${t.album}\u0000${t.albumartist || t.artist || ""}` : "") : t[field] || "");
  for (const t of S.tracks) {
    const k = keyOf(t);
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(t);
  }
  const nice = (k) => (k ? (field === "album" ? k.split("\u0000")[0] + (k.split("\u0000")[1] ? ` · ${k.split("\u0000")[1]}` : "") : k) : `(no ${label.toLowerCase()})`);
  const keys = [...groups.keys()].sort((a, b) => (!a) - (!b) || norm(a).localeCompare(norm(b)));
  main.innerHTML = `<header class="bar"><h1>${label}s</h1><span class="sub">${plural(keys.length, label.toLowerCase())}</span><span class="grow"></span>
    <button class="merge" disabled title="Give the selected ${label.toLowerCase()}s one name">Rename / merge…</button></header>
    <div class="split"><div class="groups"><div class="tools"><input type="search" class="gfilter" placeholder="Find ${label.toLowerCase()}">
    <select class="gsort"><option value="name">A-Z</option><option value="count">Most songs</option></select></div><div class="glist"></div></div>
    <div class="right">${selbar()}<div class="songs"></div></div></div>`;
  const table = new SongTable($(".songs", main), { emptyText: `Pick a ${label.toLowerCase()} on the left (Ctrl/Shift for several)` });
  S.table = table;
  const chosen = new Set(S.groupSel?.[field] || []);
  const list = $(".glist", main);
  const show = () => {
    const q = norm($(".gfilter", main).value);
    let ks = keys.filter((k) => !q || norm(nice(k)).includes(q));
    if ($(".gsort", main).value === "count") ks = ks.slice().sort((a, b) => groups.get(b).length - groups.get(a).length);
    list.innerHTML = ks.slice(0, 4000).map((k) => `<div class="gitem${chosen.has(k) ? " sel" : ""}" data-k="${esc(k)}"><span>${esc(nice(k))}</span><span class="count">${groups.get(k).length}</span></div>`).join("");
  };
  const apply = () => {
    S.groupSel = { ...(S.groupSel || {}), [field]: [...chosen] };
    table.set([...chosen].flatMap((k) => groups.get(k) || []));
    $(".merge", main).disabled = !chosen.size || field === "folder";
  };
  let last = null;
  list.addEventListener("click", (e) => {
    const it = e.target.closest(".gitem");
    if (!it) return;
    const k = it.dataset.k;
    const visible = [...list.querySelectorAll(".gitem")].map((x) => x.dataset.k);
    if (e.shiftKey && last !== null) {
      const [a, b] = [visible.indexOf(last), visible.indexOf(k)].sort((x, y) => x - y);
      visible.slice(a, b + 1).forEach((x) => chosen.add(x));
    } else if (e.ctrlKey || e.metaKey) chosen.has(k) ? chosen.delete(k) : chosen.add(k);
    else { chosen.clear(); chosen.add(k); }
    last = k;
    show();
    apply();
  });
  list.addEventListener("dblclick", (e) => { const it = e.target.closest(".gitem"); if (it) play(groups.get(it.dataset.k), 0); });
  $(".gfilter", main).addEventListener("input", debounce(show, 60));
  $(".gsort", main).addEventListener("change", show);
  $(".merge", main).addEventListener("click", () => {
    const names = [...chosen].map(nice);
    const songs = [...chosen].flatMap((k) => groups.get(k));
    const tagField = field === "album" ? "album" : field;
    modal(`<h2>Rename ${esc(label.toLowerCase())}${chosen.size > 1 ? "s" : ""}</h2>
      <p>${chosen.size > 1 ? `Merges <b>${names.map(esc).join("</b>, <b>")}</b> into one name` : `Renames <b>${esc(names[0])}</b>`} on ${plural(songs.length, "song")}.</p>
      <div class="field"><label>New name</label><input type="text" name="v" list="dl-${tagField}" value="${esc(chosen.size === 1 ? (field === "album" ? [...chosen][0].split("\u0000")[0] : [...chosen][0]) : "")}"></div>${datalists()}
      <div class="actions"><button data-close>Cancel</button><button class="primary ok">Save</button></div>`, async (m) => {
      const v = $("input", m).value.trim();
      await runAndReload(api("/api/tags", { paths: songs.map((t) => t.path), fields: { [tagField]: v } }), () => `Renamed on ${plural(songs.length, "song")}`);
      chosen.clear();
      if (v) chosen.add(field === "album" ? `${v}\u0000${songs[0].albumartist || songs[0].artist || ""}` : v);
      S.groupSel = { ...(S.groupSel || {}), [field]: [...chosen] };
    });
  });
  show();
  apply();
  wireSelbar(main, table);
}

views.artists = (main) => groupView(main, "artist", "Artist");
views.albums = (main) => groupView(main, "album", "Album");
views.genres = (main) => groupView(main, "genre", "Genre");
views.folders = (main) => groupView(main, "folder", "Folder");

views.playlist = (main, path) => {
  const p = S.playlists.find((x) => x.path === path);
  if (!p) { main.innerHTML = `<div class="pad">This playlist is gone.</div>`; return; }
  const tracks = p.tracks.map((x) => S.byPath.get(x)).filter(Boolean);
  const save = async (order) => {
    try { await api("/api/playlist/save", { path: p.path, tracks: order }); await loadLibrary(true); } catch (e) { toast(e.message); }
  };
  const table = songView(main, {
    title: p.name, tracks, ordered: true, onReorder: save,
    sub: `${plural(tracks.length, "song")} · drag to reorder${p.missing ? ` · ${p.missing} missing` : ""}`,
    extraBar: `<button data-a="unlist">Remove from playlist</button>`,
    head: `<button class="play-all">Play</button><button class="ren">Rename</button><button class="del danger">Delete playlist</button>`,
    emptyText: "Empty - drag songs onto this playlist in the sidebar, or use Add to playlist.",
  });
  table.sort = null;
  table.refresh();
  actions.unlist = () => save(p.tracks.filter((x) => !S.selected.has(x)));
  $(".play-all", main).addEventListener("click", () => play(table.rows, 0));
  $(".ren", main).addEventListener("click", () => modal(`<h2>Rename playlist</h2><div class="field"><label>Name</label><input type="text" value="${esc(p.name)}"></div>
    <div class="actions"><button data-close>Cancel</button><button class="primary ok">Rename</button></div>`, async (m) => {
    try { const r = await api("/api/playlist/rename", { path: p.path, name: $("input", m).value }); await loadLibrary(true); location.hash = "#playlist/" + encodeURIComponent(r.path); }
    catch (e) { toast(e.message); return false; }
  }));
  $(".del", main).addEventListener("click", async () => {
    if (!confirm(`Delete the playlist "${p.name}"? The songs stay.`)) return;
    await api("/api/playlist/delete", { path: p.path });
    await loadLibrary(true);
    location.hash = "#songs";
  });
};

// ------------------------------------------------------------------ get music
function getView(main, kind) {
  if (!S.state.musicOk) return noLibrary(main);
  const forms = {
    search: { title: "Search YouTube", help: "Search like on YouTube and pick the right videos.",
      form: `<input type="search" name="query" placeholder="e.g. Stromae Alors on danse" size="44"><button class="primary go">Search</button>`,
      body: (f) => ({ query: f.query.value, count: 15 }) },
    artist: { title: "An artist's top songs", help: "The artist's most played songs (from Deezer's charts).",
      form: `<input type="text" name="artist" placeholder="Artist" list="dl-artist" size="30"> Top <input type="number" name="count" value="10" min="1" max="100" style="width:64px"><button class="primary go">Find</button>${datalists()}`,
      body: (f) => ({ artist: f.artist.value, count: f.count.value }) },
    chart: { title: "Charts", help: "A country's chart right now (Deezer), or its official chart of a year (Claude looks that one up, so it needs the API key in Settings).",
      form: `<select name="country">${S.state.countries.map((c) => `<option>${esc(c)}</option>`).join("")}</select> Top <input type="number" name="count" value="50" min="1" max="100" style="width:64px">
        <select name="period" title="Period"><option value="">right now</option>${yearOptions()}</select><button class="primary go">Get chart</button>`,
      // A year's chart isn't on Deezer: it becomes an Ask-for-a-list prompt.
      source: (f) => (f.period.value ? "ask" : "chart"),
      body: (f) => f.period.value
        ? { prompt: yearChartPrompt(f.country.value, f.count.value, f.period.value) }
        : { country: f.country.value, count: f.count.value } },
    ask: { title: "Ask for a list", help: "Describe the list in your own words. Claude looks it up on the web (official charts, streaming numbers) and you check it before downloading.",
      form: `<textarea name="prompt" placeholder="e.g. The top 10 songs of the Belgian Ultratop year chart 2026&#10;The 15 most streamed songs of Dua Lipa&#10;20 Belgian summer hits from the 2000s" style="min-height:80px"></textarea><button class="primary go">Make the list</button>`,
      body: (f) => ({ prompt: f.prompt.value }) },
    paste: { title: "Paste a list", help: "One song per line: \"Artist - Title\", \"Title by Artist\" or a YouTube link. Numbers in front are fine.",
      form: `<textarea name="text" placeholder="1. Stromae - Papaoutai&#10;Angèle - Balance ton quoi&#10;https://www.youtube.com/watch?v=..."></textarea><button class="primary go">Read the list</button>`,
      body: (f) => ({ text: f.text.value }) },
  };
  const F = forms[kind];
  main.innerHTML = `<header class="bar"><h1>${F.title}</h1><span class="sub">${F.help}</span></header>
    <div class="pad"><form class="form-row src" onsubmit="return false">${F.form}</form><div class="status sub"></div><div class="cands"></div></div>`;
  const form = $(".src", main);
  if (S.candidates?.kind === kind) showCandidates(main, S.candidates.songs, S.candidates.summary);
  const go = async () => {
    const st = $(".status", main);
    const source = F.source ? F.source(form) : kind;
    st.textContent = source === "ask" ? "Claude is looking this up (can take a minute)…" : "Looking…";
    $(".go", main).disabled = true;
    try {
      let r = await api(`/api/source/${source}`, F.body(form));
      if (r.id && r.status) r = await waitJob(r, (j) => (st.textContent = j.message || st.textContent));
      st.textContent = r.summary || "";
      S.candidates = { kind, songs: r.songs, summary: r.summary };
      showCandidates(main, r.songs, r.summary);
    } catch (e) { st.textContent = ""; toast(e.message, 6000); }
    $(".go", main).disabled = false;
  };
  $(".go", main).addEventListener("click", go);
  form.querySelectorAll("input").forEach((i) => i.addEventListener("keydown", (e) => e.key === "Enter" && go()));
  form.querySelector("input,textarea")?.focus();
}

/** This year and the 15 before it, newest first, for the Charts period picker. */
function yearOptions() {
  const now = new Date().getFullYear();
  return Array.from({ length: 16 }, (_, i) => `<option value="${now - i}">year ${now - i}${i === 0 ? " so far" : ""}</option>`).join("");
}

function yearChartPrompt(country, count, year) {
  const soFar = +year === new Date().getFullYear() ? " (the year so far: the official year-to-date ranking if there is one, otherwise the songs that charted highest and longest this year)" : "";
  return `The top ${count} songs of ${country}'s official year-end singles chart for ${year}${soFar}, in chart order. For Belgium use the Ultratop (Flanders) year chart.`;
}

function showCandidates(main, songs, summary) {
  const box = $(".cands", main);
  if (!songs.length) { box.innerHTML = `<p class="sub">Nothing found.</p>`; return; }
  const sel = songs.map((s) => !s.have);
  box.innerHTML = `<table class="list"><thead><tr><th style="width:28px"><input type="checkbox" class="all"></th><th>#</th><th>Artist</th><th>Title</th><th>Info</th><th></th></tr></thead><tbody>${songs.map((s, i) => `
    <tr data-i="${i}"><td><input type="checkbox" class="pick"${sel[i] ? " checked" : ""}></td><td class="sub">${i + 1}</td>
    <td><input type="text" class="artist" value="${esc(s.artist)}"></td><td><input type="text" class="title" value="${esc(s.title)}" placeholder="${s.url ? "(from the video)" : ""}"></td>
    <td class="sub">${esc(s.note || "")}${s.url ? ` <a href="${esc(s.url)}" target="_blank" rel="noopener">video</a>` : ""}</td>
    <td>${s.have ? `<span class="badge ok" title="${esc(s.have)}">already have</span>` : ""}</td></tr>`).join("")}</tbody></table>
    <div class="form-row" style="margin-top:12px"><span>Save as</span>${patternSelect(S.state.config.pattern)}
    <label class="inline">Add to playlist <input type="text" class="pl" list="dl-pl" placeholder="(none)" size="22"></label>
    <datalist id="dl-pl">${S.playlists.map((p) => `<option value="${esc(p.name)}">`).join("")}</datalist>
    <button class="primary dl">Download selected</button><span class="dlstatus sub"></span></div>`;
  wirePattern(box);
  const rows = [...box.querySelectorAll("tbody tr")];
  const sync = () => rows.forEach((r) => r.classList.toggle("off", !$(".pick", r).checked));
  $(".all", box).addEventListener("change", (e) => { rows.forEach((r) => ($(".pick", r).checked = e.target.checked)); sync(); });
  box.addEventListener("change", sync);
  sync();
  $(".dl", box).addEventListener("click", async () => {
    const picked = rows.filter((r) => $(".pick", r).checked).map((r) => {
      const s = songs[+r.dataset.i];
      return { ...s, artist: $(".artist", r).value.trim(), title: $(".title", r).value.trim() };
    });
    if (!picked.length) return toast("Tick the songs to download");
    const st = $(".dlstatus", box);
    $(".dl", box).disabled = true;
    try {
      const job = await api("/api/download", { songs: picked, pattern: $(".pattern", box).value, playlist: $(".pl", box).value });
      const res = await waitJob(job, (j) => (st.textContent = j.message));
      st.textContent = `${plural(res.downloaded.length, "song")} downloaded${res.failed.length ? `, ${res.failed.length} failed` : ""}`;
      if (res.failed.length) toast(res.failed.map((f) => `${f.song}: ${f.error}`).join(" · "), 8000);
      await loadLibrary(true);
    } catch (e) { toast(e.message, 6000); st.textContent = ""; }
    $(".dl", box).disabled = false;
  });
}

["search", "artist", "chart", "ask", "paste"].forEach((k) => (views["get/" + k] = (main) => getView(main, k)));

// ------------------------------------------------------------------ tidy
views["tidy/names"] = async (main) => {
  if (!S.state.musicOk) return noLibrary(main);
  main.innerHTML = `<header class="bar"><h1>Clean up names</h1><span class="sub">Strips "(Official Video)", "- Topic", track numbers and underscores, fixes ALL CAPS, takes the artist out of "Artist - Title" titles.</span></header><div class="pad"><p class="sub">Looking…</p></div>`;
  let list = await api("/api/cleanup");
  if (S.cleanOnly) { list = list.filter((x) => S.cleanOnly.has(x.path)); S.cleanOnly = null; }
  const pad = $(".pad", main);
  if (!list.length) { pad.innerHTML = `<p>Nothing to clean up. 🎉</p>`; return; }
  pad.innerHTML = `<div class="form-row"><b>${plural(list.length, "song")}</b><label class="inline"><input type="checkbox" class="also" checked> and rename the files by</label>${patternSelect(S.state.config.pattern)}
    <button class="primary apply">Apply to ticked</button></div>
    <table class="list"><thead><tr><th><input type="checkbox" class="all" checked></th><th>Artist</th><th>Title</th><th>Why</th><th>File</th></tr></thead><tbody>${list.map((x, i) => `
    <tr data-i="${i}"><td><input type="checkbox" class="pick" checked></td>
    <td>${x.changes.artist !== undefined ? `<span class="old">${esc(x.artist)}</span><br><input type="text" class="artist" value="${esc(x.changes.artist)}">` : esc(x.artist)}</td>
    <td>${x.changes.title !== undefined ? `<span class="old">${esc(x.title)}</span><br><input type="text" class="title" value="${esc(x.changes.title)}">` : esc(x.title)}</td>
    <td class="sub">${esc(x.reasons.join(", "))}</td><td class="sub mono">${esc(x.path)}</td></tr>`).join("")}</tbody></table>`;
  wirePattern(pad);
  const rows = [...pad.querySelectorAll("tbody tr")];
  $(".all", pad).addEventListener("change", (e) => rows.forEach((r) => ($(".pick", r).checked = e.target.checked)));
  $(".apply", pad).addEventListener("click", async () => {
    const items = rows.filter((r) => $(".pick", r).checked).map((r) => {
      const x = list[+r.dataset.i], fields = {};
      if ($(".artist", r)) fields.artist = $(".artist", r).value.trim();
      if ($(".title", r)) fields.title = $(".title", r).value.trim();
      return { path: x.path, fields };
    });
    if (!items.length) return;
    await runAndReload(api("/api/retag", { items }), (r) => `Cleaned ${plural(r.done, "song")}`);
    if ($(".also", pad).checked) {
      await runAndReload(api("/api/move", { paths: items.map((i) => i.path), pattern: $(".pattern", pad).value }), (r) => `Cleaned and renamed ${plural(r.done, "song")}`);
    }
    render();
  });
};

views["tidy/group"] = (main) => {
  if (!S.state.musicOk) return noLibrary(main);
  main.innerHTML = `<header class="bar"><h1>Group into folders</h1><span class="sub">Moves every song into folders made from its tags. Fix the tags first (Clean up names, Missing info).</span></header>
    <div class="pad"><div class="form-row">${patternSelect(S.state.config.pattern)}<label class="inline"><input type="checkbox" class="keep"> make this my default</label><button class="primary apply" disabled>Move</button></div>
    <p class="sub">${PATTERN_HELP} Playlists follow their songs.</p><div class="pv"></div></div>`;
  wirePattern(main);
  let moves = [];
  const preview = async () => {
    moves = await api("/api/organize/preview", { pattern: $(".pattern", main).value });
    $(".apply", main).disabled = !moves.length;
    $(".apply", main).textContent = moves.length ? `Move ${plural(moves.length, "song")}` : "Move";
    $(".pv", main).innerHTML = moves.length ? `<table class="list"><thead><tr><th>Now</th><th>Becomes</th></tr></thead><tbody>${moves.slice(0, 500).map((x) => `<tr><td class="mono old">${esc(x.from)}</td><td class="mono new">${esc(x.to)}</td></tr>`).join("")}</tbody></table>${moves.length > 500 ? `<p class="sub">…and ${moves.length - 500} more</p>` : ""}`
      : `<p>Everything is already in place.</p>`;
  };
  $(".pattern", main).addEventListener("input", debounce(preview, 250));
  $(".apply", main).addEventListener("click", async () => {
    if (!confirm(`Move ${plural(moves.length, "song")}? The Pi follows at the next sync.`)) return;
    if ($(".keep", main).checked) await api("/api/config", { pattern: $(".pattern", main).value });
    await runAndReload(api("/api/move", { moves }), (r) => `Moved ${plural(r.done, "song")}`);
    preview();
  });
  preview();
};

views["tidy/dupes"] = async (main) => {
  if (!S.state.musicOk) return noLibrary(main);
  main.innerHTML = `<header class="bar"><h1>Duplicates</h1><span class="sub">Same artist and title (spelling, case and "feat." ignored). The best copy (highest bitrate) is ticked to keep.</span></header><div class="pad"><p class="sub">Looking…</p></div>`;
  const groups = await api("/api/duplicates");
  const pad = $(".pad", main);
  if (!groups.length) { pad.innerHTML = `<p>No duplicates. 🎉</p>`; return; }
  pad.innerHTML = `<div class="form-row"><b>${plural(groups.length, "song")} with more than one copy</b><button class="primary apply">Delete the unticked copies</button></div>
    ${groups.map((g, gi) => `<details open><summary>${esc(g.tracks[0].artist)} — ${esc(g.tracks[0].title)} <span class="count">${g.tracks.length} copies</span></summary>
    <table class="list"><tbody>${g.tracks.map((t, i) => `<tr><td style="width:28px"><input type="checkbox" class="keep" data-g="${gi}" data-p="${esc(t.path)}"${i === 0 ? " checked" : ""}></td>
    <td class="mono">${esc(t.path)}</td><td class="sub">${t.bitrate ? t.bitrate + " kbps" : ""}</td><td class="sub">${dur(t.duration)}</td><td class="sub">${mb(t.size || 0)}</td>
    <td><button class="mini playone" data-p="${esc(t.path)}">▶</button></td></tr>`).join("")}</tbody></table></details>`).join("")}`;
  pad.addEventListener("click", (e) => { if (e.target.classList.contains("playone")) play([S.byPath.get(e.target.dataset.p)].filter(Boolean), 0); });
  $(".apply", pad).addEventListener("click", async () => {
    const del = [...pad.querySelectorAll(".keep")].filter((c) => !c.checked).map((c) => c.dataset.p);
    const kept = new Set([...pad.querySelectorAll(".keep:checked")].map((c) => c.dataset.g));
    if (groups.some((_, gi) => !kept.has(String(gi)))) return toast("Keep at least one copy of every song");
    if (!del.length || !confirm(`Delete ${plural(del.length, "copy")}?`)) return;
    await runAndReload(api("/api/delete", { paths: del }), (r) => `Deleted ${plural(r.done, "copy")}`);
    render();
  });
};

views["tidy/missing"] = (main) => {
  if (!S.state.musicOk) return noLibrary(main);
  const kinds = { artist: "no artist", title: "no title", genre: "no genre", album: "no album", year: "no year" };
  const pick = S.missingKind || "artist";
  const tracks = S.tracks.filter((t) => !t[pick]);
  songView(main, { title: "Missing info", tracks, sub: `${plural(tracks.length, "song")} with ${kinds[pick]} · select and Edit info, or double-click a cell`,
    head: `<select class="mk">${Object.entries(kinds).map(([k, l]) => `<option value="${k}"${k === pick ? " selected" : ""}>${l}</option>`).join("")}</select>` });
  $(".mk", main).addEventListener("change", (e) => { S.missingKind = e.target.value; render(); });
};

// ------------------------------------------------------------------ sync
views.sync = (main) => {
  if (!S.state.musicOk) return noLibrary(main);
  const c = S.state.config;
  main.innerHTML = `<header class="bar"><h1>Sync to the Pi</h1><span class="sub">ssh ${esc(c.piHost)} · organize here, then send the result to the music server in one go</span><span class="grow"></span>
    <button class="primary check">Check what changed</button></header><div class="pad"><div class="plan"><p class="sub">Compares this computer with the Pi; nothing changes until you press Sync.</p></div></div>`;
  $(".check", main).addEventListener("click", async () => {
    const box = $(".plan", main);
    box.innerHTML = `<p class="sub">Asking the Pi…</p>`;
    try {
      const plan = await waitJob(await api("/api/sync/plan", {}));
      showPlan(box, plan);
    } catch (e) { box.innerHTML = `<p style="color:var(--bad)">${esc(e.message)}</p><p class="sub">Check Settings → Pi SSH host, and that <span class="mono">ssh ${esc(c.piHost)}</span> works in a terminal without a password.</p>`; }
  });
};

function showPlan(box, plan) {
  const top = (p) => (p.includes("/") ? p.slice(0, p.indexOf("/")) : "(top folder)");
  const byTop = {};
  plan.remoteOnly.forEach((p) => (byTop[top(p)] = byTop[top(p)] || []).push(p));
  const ops = plan.ops;
  box.innerHTML = `<div class="cards">
    <div class="card"><b>${ops.length}</b>moves, renames, deletes to repeat on the Pi</div>
    <div class="card"><b>${plan.upload.length}</b>files to copy (${mb(plan.uploadBytes)})</div>
    <div class="card"><b>${plan.remoteOnly.length}</b>files only on the Pi (${mb(plan.remoteOnlyBytes)})</div>
    <div class="card"><b>${plan.local}</b>files here · ${plan.remote} on the Pi</div></div>
    ${ops.length ? `<details><summary>Changes made here</summary><div class="scroll mono">${ops.map((o) => o.kind === "move" ? `${esc(o.src)} → ${esc(o.dst)}` : `delete ${esc(o.src)}`).join("<br>")}</div></details>` : ""}
    ${plan.upload.length ? `<details><summary>Files to copy</summary><div class="scroll mono">${plan.upload.slice(0, 2000).map(esc).join("<br>")}</div></details>` : ""}
    ${plan.remoteOnly.length ? `<details open><summary>Only on the Pi - what should happen with them?</summary>
      <p class="sub">For example songs uploaded from the phone (Phone/). Getting them here lets you organize them too.</p>
      <table class="list"><thead><tr><th>Folder</th><th>Files</th><th>Get them here</th><th>Move to the Pi's trash</th><th>Leave</th></tr></thead><tbody>
      ${Object.entries(byTop).map(([t, ps], i) => `<tr><td>${esc(t)}</td><td>${ps.length}</td>
        <td><input type="radio" name="r${i}" value="pull" data-t="${esc(t)}"${t === "Phone" ? " checked" : ""}></td>
        <td><input type="radio" name="r${i}" value="trash" data-t="${esc(t)}"></td>
        <td><input type="radio" name="r${i}" value="leave" data-t="${esc(t)}"${t === "Phone" ? "" : " checked"}></td></tr>`).join("")}</tbody></table></details>` : ""}
    <div class="form-row" style="margin-top:14px"><label class="inline"><input type="checkbox" class="scan"${S.state.config.piScanAfterSync ? " checked" : ""}> Let the server scan right away (otherwise tonight)</label>
    <button class="primary run">Sync now</button><span class="runstatus sub"></span></div>`;
  $(".run", box).addEventListener("click", async () => {
    const pull = [], trash = [];
    box.querySelectorAll("input[type=radio]:checked").forEach((r) => {
      const ps = byTop[r.dataset.t] || [];
      if (r.value === "pull") pull.push(...ps);
      if (r.value === "trash") trash.push(...ps);
    });
    if (trash.length && !confirm(`Move ${plural(trash.length, "file")} on the Pi to its trash (kept 30 days)?`)) return;
    const st = $(".runstatus", box);
    $(".run", box).disabled = true;
    try {
      const r = await waitJob(await api("/api/sync/run", { pull, trash, scan: $(".scan", box).checked }), (j) => (st.textContent = j.message));
      const opsDone = Object.entries(r.ops).map(([k, v]) => `${v} ${k}`).join(", ");
      box.innerHTML = `<div class="cards"><div class="card"><b>✓</b>In sync</div><div class="card"><b>${r.uploaded}</b>copied to the Pi</div>
        <div class="card"><b>${r.pulled}</b>got from the Pi</div><div class="card"><b>${r.trashed}</b>moved to the Pi's trash</div></div>
        ${opsDone ? `<p class="sub">Changes repeated on the Pi: ${esc(opsDone)}</p>` : ""}${r.scan ? `<p class="sub mono">${esc(r.scan)}</p>` : `<p class="sub">The server adds the changes at its nightly scan.</p>`}`;
      await loadLibrary(true);
    } catch (e) { st.textContent = ""; toast(e.message, 8000); $(".run", box).disabled = false; }
  });
}

// ------------------------------------------------------------------ settings
views.settings = (main) => {
  const c = S.state.config;
  main.innerHTML = `<header class="bar"><h1>Settings</h1></header><div class="pad"><div class="field">
    <label>Music folder</label><input type="text" name="musicFolder" value="${esc(c.musicFolder)}" placeholder="e.g. D:\\Music">
    <span class="hint">The library on this computer. The organizer only works inside it.</span>
    <label>Pi SSH host</label><input type="text" name="piHost" value="${esc(c.piHost)}" placeholder="hally">
    <span class="hint">As you'd type after <span class="mono">ssh</span> (an entry in ~/.ssh/config, or user@100.88.x.x). Key login, no password.</span>
    <label>Pi music folder</label><input type="text" name="piMusicFolder" value="${esc(c.piMusicFolder)}" placeholder="(from the Pi's mirror.json)">
    <span class="hint">Leave empty: the Pi says where its music is (music.folder, /srv/music).</span>
    <label>Scan after sync</label><label class="inline"><input type="checkbox" name="piScanAfterSync"${c.piScanAfterSync ? " checked" : ""}> ask the server to scan right after every sync</label>
    <label>Songs go to</label><div>${patternSelect(c.pattern)}</div><span class="hint">${PATTERN_HELP}</span>
    <label>Download as</label><select name="downloadFormat"><option value="mp3"${c.downloadFormat === "mp3" ? " selected" : ""}>MP3 (plays everywhere)</option><option value="m4a"${c.downloadFormat === "m4a" ? " selected" : ""}>M4A (YouTube's own audio, no re-encoding)</option></select>
    <label>Anthropic API key</label><input type="password" name="anthropicApiKey" value="${esc(c.anthropicApiKey)}" placeholder="sk-ant-… (for Ask for a list)">
    <span class="hint">Or set ANTHROPIC_API_KEY. Kept in organizer/local/config.json on this computer only.</span>
    <label></label><div><button class="primary save">Save</button></div></div></div>`;
  wirePattern(main);
  $(".save", main).addEventListener("click", async () => {
    const v = {};
    main.querySelectorAll("[name]").forEach((i) => (v[i.name] = i.type === "checkbox" ? i.checked : i.value));
    v.pattern = $(".pattern", main).value;
    try {
      const st = await api("/api/config", v);
      toast("Saved");
      if (st.musicOk && (v.musicFolder !== c.musicFolder || !S.tracks.length)) await runAndReload(api("/api/scan", {}), (r) => `${plural(r.files, "song")} found`);
      else await loadLibrary(true);
    } catch (e) { toast(e.message); }
  });
};

// ------------------------------------------------------------------ jobs panel
const pollJobs = (() => {
  let timer = null, lastVersion = null;
  const tick = async () => {
    timer = null;
    let st;
    try { st = await loadState(); } catch { return schedule(4000); }
    const box = $("#jobs");
    const recent = st.jobs.filter((j) => j.status === "running" || (j.ended && Date.now() / 1000 - j.ended < 8));
    box.innerHTML = recent.map((j) => `<div class="job ${j.status}"><div class="t"><span>${esc(j.title)}</span>${j.status === "running" ? `<button class="mini" data-cancel="${j.id}" title="Stop">×</button>` : j.status === "error" ? "!" : "✓"}</div>
      <div class="m" title="${esc(j.error || j.message)}">${esc(j.error || j.message)}</div>${j.status === "running" ? `<div class="pbar"><i style="width:${Math.round(j.progress * 100)}%"></i></div>` : ""}</div>`).join("");
    if (lastVersion !== null && st.version !== lastVersion && st.version !== S.version) await loadLibrary();
    lastVersion = st.version;
    schedule(st.jobs.some((j) => j.status === "running") ? 900 : 5000);
  };
  const schedule = (ms) => { if (!timer) timer = setTimeout(tick, ms); };
  $("#jobs").addEventListener("click", (e) => { if (e.target.dataset.cancel) api("/api/job/cancel", { id: +e.target.dataset.cancel }); });
  return { start: () => schedule(10), kick: () => { clearTimeout(timer); timer = null; schedule(200); } };
})();

// ------------------------------------------------------------------ routing
function markNav() {
  document.querySelectorAll("#side a").forEach((a) => {
    const v = decodeURIComponent((a.getAttribute("href") || "").slice(1));
    a.classList.toggle("active", v === S.view);
  });
}

function render() {
  const main = $("#main");
  const [name, ...rest] = S.view.split("/");
  const arg = rest.join("/");
  const fn = views[S.view] || (name === "playlist" ? (m) => views.playlist(m, arg) : null) || views.songs;
  S.table = null;
  if (!S.state) return;
  fn(main);
  markNav();
}

function route() {
  const v = decodeURIComponent(location.hash.slice(1)) || "songs";
  if (v !== S.view) { S.filterText = ""; S.selected.clear(); }
  S.view = v;
  render();
}

window.addEventListener("hashchange", route);
$("#new-playlist").addEventListener("click", () => modal(`<h2>New playlist</h2><div class="field"><label>Name</label><input type="text" placeholder="e.g. Running"></div>
  <p class="sub">Then drag songs onto it in the sidebar, or select songs → Add to playlist.</p>
  <div class="actions"><button data-close>Cancel</button><button class="primary ok">Create</button></div>`, async (m) => {
  const name = $("input", m).value.trim();
  if (!name) return false;
  try { const r = await api("/api/playlist/save", { name, tracks: selectedPaths() }); await loadLibrary(true); location.hash = "#playlist/" + encodeURIComponent(r.path); }
  catch (e) { toast(e.message); return false; }
}));

(async function start() {
  initPlayer();
  S.view = decodeURIComponent(location.hash.slice(1)) || "songs";
  try { await loadLibrary(true); } catch (e) { $("#main").innerHTML = `<div class="pad">The organizer server is not running (${esc(e.message)}).</div>`; return; }
  if (!S.state.musicOk && !location.hash) location.hash = "#settings";
  render();
  pollJobs.start();
})();
