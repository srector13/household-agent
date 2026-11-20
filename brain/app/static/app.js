/* Household Agent dashboard runtime: one shared SSE stream, toasts, fetch helpers, live rows. */
(function () {
  const HA = (window.HA = {});
  const listeners = new Set();

  // ---- live stream ------------------------------------------------------------
  HA.on = (fn) => listeners.add(fn);
  function connect() {
    const pill = document.getElementById("live");
    const es = new EventSource("/api/stream");
    es.onopen = () => pill && pill.classList.add("on");
    es.onmessage = (m) => { let d; try { d = JSON.parse(m.data); } catch { return; } listeners.forEach((fn) => fn(d)); };
    es.onerror = () => { pill && pill.classList.remove("on"); es.close(); setTimeout(connect, 4000); };
  }

  // ---- api + toasts -------------------------------------------------------------
  HA.api = async (method, url, body) => {
    const r = await fetch(url, {
      method, headers: { "Content-Type": "application/json", "X-Requested-With": "fetch", Accept: "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    let data = {};
    try { data = await r.json(); } catch {}
    if (!r.ok || data.ok === false) throw new Error(data.error || data.detail || `HTTP ${r.status}`);
    return data;
  };
  HA.toast = (msg, kind = "ok") => {
    let box = document.querySelector(".toasts");
    if (!box) { box = document.createElement("div"); box.className = "toasts"; document.body.append(box); }
    const t = document.createElement("div");
    t.className = "toast " + kind;
    t.innerHTML = (kind === "ok" ? '<svg class="i" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M20 6 9 17l-5-5"/></svg>' : "") + "<span></span>";
    t.querySelector("span").textContent = msg;
    box.append(t);
    setTimeout(() => t.remove(), kind === "bad" ? 6000 : 3200);
  };
  HA.busy = (btn, on) => { if (btn) btn.classList.toggle("busy", on); };

  // event actions (approve/reject/undo/retry) via fetch; falls back to form submit without JS
  HA.action = async (btn, action, eventId, opts = {}) => {
    if (opts.confirm && !confirm(opts.confirm)) return;
    HA.busy(btn, true);
    try {
      const d = await HA.api("POST", `/actions/${action}/${encodeURIComponent(eventId)}`);
      HA.toast(opts.done || "Done");
      if (opts.onDone) opts.onDone(d); else setTimeout(() => location.reload(), 350);
    } catch (e) { HA.toast(e.message, "bad"); } finally { HA.busy(btn, false); }
  };

  // ---- relative times ---------------------------------------------------------------
  const rtf = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
  HA.ago = (iso) => {
    const s = (new Date(iso) - Date.now()) / 1000, a = Math.abs(s);
    if (a < 45) return "just now";
    if (a < 3600) return rtf.format(Math.round(s / 60), "minute");
    if (a < 86400) return rtf.format(Math.round(s / 3600), "hour");
    return rtf.format(Math.round(s / 86400), "day");
  };
  function tickTimes() { document.querySelectorAll("[data-ago]").forEach((el) => (el.textContent = HA.ago(el.dataset.ago))); }

  // ---- live event rows (any element with data-feed) ------------------------------------
  HA.liveFeed = (feed, { prepend = true } = {}) => {
    HA.on(async (d) => {
      if (!d.event_id) return;
      const r = await fetch("/partials/row/" + encodeURIComponent(d.event_id));
      if (!r.ok) return;
      const tpl = document.createElement("template");
      tpl.innerHTML = (await r.text()).trim();
      const node = tpl.content.firstElementChild;
      node.classList.add("flash");
      const existing = feed.querySelector(`[data-event="${CSS.escape(d.event_id)}"]`);
      if (existing) existing.replaceWith(node);
      else if (prepend) { feed.querySelector(".empty")?.remove(); feed.prepend(node); }
      tickTimes();
    });
  };

  // ---- shell bits --------------------------------------------------------------------------
  document.addEventListener("DOMContentLoaded", () => {
    connect();
    tickTimes();
    setInterval(tickTimes, 30000);
    const top = document.querySelector(".topbar");
    const onScroll = () => top && top.classList.toggle("scrolled", scrollY > 4);
    addEventListener("scroll", onScroll, { passive: true }); onScroll();
    const more = document.getElementById("more-btn"), sheet = document.getElementById("more-sheet");
    if (more) {
      more.addEventListener("click", (e) => { e.stopPropagation(); sheet.classList.toggle("open"); });
      document.addEventListener("click", () => sheet.classList.remove("open"));
    }
    // keep sidebar/tabbar review badges and agent status fresh
    HA.on((d) => {
      if (d.type === "heartbeat" || d.status) refreshShell();
    });
  });
  let shellTimer;
  function refreshShell() {
    clearTimeout(shellTimer);
    shellTimer = setTimeout(async () => {
      try {
        const o = await HA.api("GET", "/api/overview");
        document.querySelectorAll("[data-review-count]").forEach((el) => { el.textContent = o.review; el.hidden = !o.review; });
        document.querySelectorAll("[data-agent-dot]").forEach((el) => (el.className = "dot " + (o.health.agent.online ? "ok" : "bad")));
        document.querySelectorAll("[data-llm-dot]").forEach((el) => (el.className = "dot " + (o.health.llm.reachable ? "ok" : "bad")));
        if (HA.onOverview) HA.onOverview(o);
      } catch {}
    }, 400);
  }
  HA.refreshShell = refreshShell;
})();
