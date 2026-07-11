/* flac2wav frontend — multi-folder queue, one destination, live progress */
"use strict";

const $ = (id) => document.getElementById(id);
const api = async (path, body) => {
  const res = await fetch(path, body === undefined ? {} : {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error((await res.json()).error || res.statusText);
  return res.json();
};

const state = {
  queue: [],            // {path, name, folder, valid, rate, bits, size, selected}
  outdir: "",
  converting: false,
  results: [],
  pollTimer: null,
};

/* ---------------------------- queue rendering ---------------------------- */
function fmtSize(bytes) {
  if (!bytes) return "";
  const mb = bytes / 1048576;
  return mb >= 1 ? `${mb.toFixed(0)} MB` : `${(bytes / 1024).toFixed(0)} KB`;
}
function fmtMeta(f) {
  const bits = f.bits ? `${f.bits}-bit` : "";
  const rate = f.rate ? `${(f.rate / 1000).toFixed(f.rate % 1000 ? 1 : 0)} kHz` : "";
  return [bits, rate, fmtSize(f.size)].filter(Boolean).join(" · ");
}

function renderQueue() {
  const list = $("queueList");
  list.innerHTML = "";
  if (!state.queue.length) {
    list.appendChild($("queueEmpty") || Object.assign(document.createElement("div"), {}));
    $("queueEmpty")?.removeAttribute("hidden");
    $("queueTitle").textContent = "QUEUE";
    updateConvertBtn();
    return;
  }
  const groups = new Map();
  for (const f of state.queue) {
    if (!groups.has(f.folder)) groups.set(f.folder, []);
    groups.get(f.folder).push(f);
  }
  const home = state.home || "";
  for (const [folder, files] of groups) {
    const g = document.createElement("div");
    g.className = "grp";
    const shown = home && folder.startsWith(home) ? "~" + folder.slice(home.length) : folder;
    g.textContent = (folder.startsWith("/media") || folder.startsWith("/run/media") ? "🔌 " : "📁 ") + shown;
    list.appendChild(g);
    for (const f of files) {
      const row = document.createElement("div");
      row.className = "row" + (f.selected ? " sel" : "");
      row.innerHTML = `<span class="ck"></span>
        <span class="name">${f.name}${f.valid ? "" : " ⚠"}</span>
        <span class="meta">${f.valid ? fmtMeta(f) : "not a real FLAC"}</span>
        <button class="rm" title="Remove from queue">✕</button>`;
      row.addEventListener("click", (e) => {
        if (e.target.classList.contains("rm")) return;
        if (!f.valid) return;
        f.selected = !f.selected;
        renderQueue();
      });
      row.querySelector(".rm").addEventListener("click", () => {
        state.queue = state.queue.filter((x) => x.path !== f.path);
        renderQueue();
      });
      list.appendChild(row);
    }
  }
  const sel = state.queue.filter((f) => f.selected).length;
  $("queueTitle").textContent =
    `QUEUE · ${groups.size} SOURCE${groups.size > 1 ? "S" : ""} · ${sel}/${state.queue.length} selected`;
  updateConvertBtn();
}

function updateConvertBtn() {
  const sel = state.queue.filter((f) => f.selected && f.valid).length;
  const btn = $("btnConvert");
  btn.disabled = !sel || state.converting;
  btn.textContent = sel ? `Convert ${sel} →` : "Convert";
}

async function addPaths(paths) {
  if (!paths.length) return;
  const existing = new Set(state.queue.map((f) => f.path));
  const { files } = await api("/api/inspect", { paths });
  for (const f of files) {
    if (existing.has(f.path)) continue;
    f.selected = f.valid;
    state.queue.push(f);
  }
  renderQueue();
}

/* ------------------------------ file browser ----------------------------- */
const browser = {
  mode: "files",          // "files" | "folder"
  path: "",
  chosen: new Set(),
  resolve: null,
};

async function openBrowser(mode, startPath) {
  browser.mode = mode;
  browser.chosen = new Set();
  await loadDir(startPath || state.home);
  $("bHint").textContent = mode === "files"
    ? "Click FLAC files to pick them (click again to unpick). Entering a folder keeps your picks."
    : "Navigate into the folder you want, then press Select.";
  $("browser").showModal();
  return new Promise((resolve) => { browser.resolve = resolve; });
}

async function loadDir(path) {
  const data = await api("/api/browse", { path });
  browser.path = data.path;
  $("bPath").textContent = data.path;
  $("bUp").disabled = !data.parent;
  const list = $("bList");
  list.innerHTML = "";
  for (const d of data.dirs) {
    const el = document.createElement("div");
    el.className = "bitem";
    el.innerHTML = `<span class="ic">📁</span>${d}`;
    el.addEventListener("click", () => loadDir(data.path + "/" + d));
    list.appendChild(el);
  }
  if (browser.mode === "files") {
    for (const f of data.flacs) {
      const full = data.path + "/" + f;
      const el = document.createElement("div");
      el.className = "bitem" + (browser.chosen.has(full) ? " sel" : "");
      el.innerHTML = `<span class="ic">🎵</span>${f}`;
      el.addEventListener("click", () => {
        browser.chosen.has(full) ? browser.chosen.delete(full) : browser.chosen.add(full);
        el.classList.toggle("sel");
        $("bOk").textContent = browser.chosen.size ? `Add ${browser.chosen.size}` : "Select";
      });
      list.appendChild(el);
    }
    if (!data.dirs.length && !data.flacs.length) {
      list.innerHTML = `<div class="empty dim">Empty folder</div>`;
    }
  }
}

function closeBrowser(result) {
  $("browser").close();
  $("bOk").textContent = "Select";
  browser.resolve?.(result);
  browser.resolve = null;
}

/* ------------------------------- conversion ------------------------------ */
async function startConvert() {
  const files = state.queue.filter((f) => f.selected && f.valid).map((f) => f.path);
  if (!files.length) return;
  try {
    await api("/api/convert", {
      files, outdir: state.outdir, overwrite: $("chkOverwrite").checked,
    });
  } catch (err) { alert(err.message); return; }
  state.converting = true;
  $("btnCancel").hidden = false;
  $("statusLine").hidden = false;
  updateConvertBtn();
  poll();
  state.pollTimer = setInterval(poll, 500);
}

const stateIcon = { pending: ["wait", "◌"], converting: ["", ""], done: ["ok", "✓"],
                    failed: ["err", "✗"], skipped: ["wait", "⏭"], cancelled: ["err", "✕"] };

async function poll() {
  const s = await api("/api/progress");
  const out = $("outList");
  out.innerHTML = "";
  let overallDone = 0;
  for (const item of s.items) {
    const name = item.src.split("/").pop();
    const row = document.createElement("div");
    row.className = "row";
    if (item.state === "converting") {
      row.innerHTML = `<span class="state">⟳</span><span class="name">${name}</span>
        <div class="fbar"><div style="width:${item.percent}%"></div></div>`;
      overallDone += item.percent / 100;
    } else if (item.state === "done") {
      const outName = item.out.split("/").pop();
      row.innerHTML = `<span class="state ok">✓</span><span class="name">${outName}</span>
        <span class="badge">16/44.1</span>`;
      overallDone += 1;
    } else {
      const [cls, icon] = stateIcon[item.state] || ["", "?"];
      const note = item.state === "failed" ? ` — ${item.error}` :
                   item.state === "skipped" ? " — exists (overwrite off)" : "";
      row.innerHTML = `<span class="state ${cls}">${icon}</span>
        <span class="name">${name}${note}</span>`;
      if (item.state === "skipped" || item.state === "failed" || item.state === "cancelled") overallDone += 1;
    }
    out.appendChild(row);
  }
  const pct = s.total ? Math.round((overallDone / s.total) * 100) : 0;
  $("gbarFill").style.width = pct + "%";
  $("gbarText").textContent = s.running
    ? `${s.done + s.failed + s.skipped} of ${s.total}`
    : `done: ${s.done} · skipped: ${s.skipped} · failed: ${s.failed}`;
  $("outTitle").textContent = s.running ? "OUTPUT · CONVERTING…" : "OUTPUT · READY FOR USB";

  if (!s.running && state.converting) {
    state.converting = false;
    clearInterval(state.pollTimer);
    $("btnCancel").hidden = true;
    $("outFoot").hidden = false;
    updateConvertBtn();
  }
}

/* --------------------------------- wiring -------------------------------- */
(async function init() {
  const d = await api("/api/defaults");
  state.home = d.home;
  state.outdir = d.outdir;
  $("destPath").textContent = d.outdir.replace(d.home, "~");

  $("btnAddFiles").addEventListener("click", async () => {
    const picked = await openBrowser("files");
    if (picked?.length) await addPaths(picked);
  });
  $("btnAddFolder").addEventListener("click", async () => {
    const folder = await openBrowser("folder");
    if (!folder) return;
    const data = await api("/api/browse", { path: folder });
    await addPaths(data.flacs.map((f) => data.path + "/" + f));
  });
  $("btnSelectAll").addEventListener("click", () => {
    const allSel = state.queue.every((f) => f.selected || !f.valid);
    state.queue.forEach((f) => { if (f.valid) f.selected = !allSel; });
    renderQueue();
  });
  $("btnClear").addEventListener("click", () => { state.queue = []; renderQueue(); });
  $("destBox").addEventListener("click", async () => {
    const folder = await openBrowser("folder", state.outdir.replace(/\/[^/]*$/, ""));
    if (folder) {
      state.outdir = folder;
      $("destPath").textContent = folder.replace(state.home, "~");
    }
  });
  $("btnConvert").addEventListener("click", startConvert);
  $("btnCancel").addEventListener("click", () => api("/api/cancel", {}));
  $("btnReveal").addEventListener("click", () => api("/api/reveal", { path: state.outdir }));

  $("bUp").addEventListener("click", () => {
    const parent = browser.path.replace(/\/[^/]+\/?$/, "") || "/";
    loadDir(parent);
  });
  $("bCancel").addEventListener("click", () => closeBrowser(null));
  $("bOk").addEventListener("click", () => {
    closeBrowser(browser.mode === "files" ? [...browser.chosen] : browser.path);
  });
})();
