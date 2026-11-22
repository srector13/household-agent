/* Second Brain dashboard runtime: SSE, iOS-style action sheets + banners, nav bar, pull-to-refresh, PWA. */
(function () {
  const HA = (window.HA = {});
  const listeners = new Set();
  const standalone = window.navigator.standalone === true || matchMedia("(display-mode: standalone)").matches;
  document.documentElement.classList.toggle("standalone", standalone);

  // ---- live stream ------------------------------------------------------------
  HA.on = (fn) => listeners.add(fn);
  function connect() {
    const pill = document.getElementById("live");
    const es = new EventSource("/api/stream");
    es.onopen = () => pill && pill.classList.add("on");
    es.onmessage = (m) => { let d; try { d = JSON.parse(m.data); } catch { return; } listeners.forEach((fn) => fn(d)); };
    es.onerror = () => { pill && pill.classList.remove("on"); es.close(); setTimeout(connect, 4000); };
  }
  // iOS suspends background tabs/PWAs: refresh state when coming back to the foreground
  document.addEventListener("visibilitychange", () => { if (!document.hidden) HA.refreshShell && HA.refreshShell(); });

  // ---- api ------------------------------------------------------------------------
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
  HA.busy = (btn, on) => { if (btn) btn.classList.toggle("busy", on); };

  // ---- banner toasts (top of screen, like a notification) ---------------------------
  const CHECK = '<svg class="i" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="m8 12 3 3 5-6"/></svg>';
  const WARN = '<svg class="i" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M12 8v5"/><path d="M12 16h.01"/></svg>';
  HA.toast = (msg, kind = "ok") => {
    let box = document.querySelector(".toasts");
    if (!box) { box = document.createElement("div"); box.className = "toasts"; document.body.append(box); }
    const t = document.createElement("div");
    t.className = "toast " + kind;
    t.innerHTML = (kind === "bad" ? WARN : CHECK) + "<span></span>";
    t.querySelector("span").textContent = msg;
    box.append(t);
    const close = () => { t.classList.add("out"); setTimeout(() => t.remove(), 260); };
    t.addEventListener("click", close);
    setTimeout(close, kind === "bad" ? 5000 : 2600);
  };

  // ---- action sheets ------------------------------------------------------------------
  function sheet(build) {
    return new Promise((resolve) => {
      const back = document.createElement("div"); back.className = "backdrop";
      const el = document.createElement("div"); el.className = "asheet"; el.setAttribute("role", "dialog");
      const done = (v) => {
        el.classList.remove("show"); back.classList.remove("show");
        setTimeout(() => { el.remove(); back.remove(); }, 320); resolve(v);
      };
      build(el, done);
      const cancel = document.createElement("button"); cancel.className = "cancel"; cancel.textContent = "Cancel";
      cancel.onclick = () => done(false);
      el.append(cancel);
      back.onclick = () => done(false);
      document.body.append(back, el);
      requestAnimationFrame(() => { back.classList.add("show"); el.classList.add("show"); });
    });
  }
  /** iOS action sheet confirm. Resolves true/false. */
  HA.confirm = (message, action = "OK", { destructive = false } = {}) => sheet((el, done) => {
    const g = document.createElement("div"); g.className = "group";
    const m = document.createElement("div"); m.className = "msg"; m.textContent = message;
    const b = document.createElement("button"); b.textContent = action; if (destructive) b.className = "destructive";
    b.onclick = () => done(true);
    g.append(m, b); el.append(g);
  });
  /** Action sheet with several choices: [{key, label, destructive}] → resolves the chosen key (or false). */
  HA.choose = (message, options) => sheet((el, done) => {
    const g = document.createElement("div"); g.className = "group";
    if (message) { const m = document.createElement("div"); m.className = "msg"; m.textContent = message; g.append(m); }
    options.forEach((o) => {
      const b = document.createElement("button"); b.textContent = o.label; if (o.destructive) b.className = "destructive";
      b.onclick = () => done(o.key); g.append(b);
    });
    el.append(g);
  });
  HA.menu = (html) => sheet((el) => {
    const g = document.createElement("div"); g.className = "group"; g.innerHTML = html; el.append(g);
  });

  // event actions (approve/reject/undo/retry)
  HA.action = async (btn, action, eventId, opts = {}) => {
    if (opts.confirm && !(await HA.confirm(opts.confirm, opts.confirmLabel || cap(action), { destructive: ["undo", "reject"].includes(action) }))) return;
    HA.busy(btn, true);
    try {
      const d = await HA.api("POST", `/actions/${action}/${encodeURIComponent(eventId)}`);
      HA.toast(opts.done || "Done");
      if (opts.onDone) opts.onDone(d); else setTimeout(() => location.reload(), 350);
    } catch (e) { HA.toast(e.message, "bad"); } finally { HA.busy(btn, false); }
  };
  const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);

  // ---- relative times -------------------------------------------------------------------
  const rtf = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
  HA.ago = (iso) => {
    const s = (new Date(iso) - Date.now()) / 1000, a = Math.abs(s);
    if (a < 45) return "now";
    if (a < 3600) return rtf.format(Math.round(s / 60), "minute");
    if (a < 86400) return rtf.format(Math.round(s / 3600), "hour");
    if (a < 86400 * 6) return new Date(iso).toLocaleDateString(undefined, { weekday: "long" });
    return new Date(iso).toLocaleDateString(undefined, { month: "numeric", day: "numeric", year: "2-digit" });
  };
  function tickTimes() { document.querySelectorAll("[data-ago]").forEach((el) => (el.textContent = HA.ago(el.dataset.ago))); }

  // ---- live event rows ---------------------------------------------------------------------
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

  // ---- nav bar: inline title once the large title scrolls away ---------------------------------
  function navbar() {
    const bar = document.getElementById("navbar"), big = document.getElementById("largeTitle");
    if (!bar || !big) return;
    const io = new IntersectionObserver(([e]) => bar.classList.toggle("solid", !e.isIntersecting),
      { rootMargin: `-${bar.offsetHeight}px 0px 0px 0px`, threshold: 0 });
    io.observe(big);
  }

  // ---- pull to refresh (standalone apps have no reload button) ----------------------------------
  function pullToRefresh() {
    const ptr = document.getElementById("ptr");
    if (!ptr || !("ontouchstart" in window)) return;
    let y0 = null, dy = 0;
    addEventListener("touchstart", (e) => { if (scrollY <= 0 && !document.querySelector(".asheet")) { y0 = e.touches[0].clientY; dy = 0; } }, { passive: true });
    addEventListener("touchmove", (e) => {
      if (y0 === null) return;
      dy = e.touches[0].clientY - y0;
      if (dy <= 0) { ptr.style.opacity = 0; return; }
      const p = Math.min(dy / 90, 1);
      ptr.style.opacity = p; ptr.style.transform = `scale(${0.6 + p * 0.4}) rotate(${dy * 2}deg)`;
      ptr.classList.toggle("armed", p >= 1);
    }, { passive: true });
    addEventListener("touchend", () => {
      if (y0 !== null && dy >= 90) { ptr.classList.add("loading"); ptr.style.transform = "scale(1)"; setTimeout(() => location.reload(), 150); }
      else { ptr.style.opacity = 0; }
      y0 = null;
    });
  }

  // ---- floating tab bar shrinks while scrolling down (Liquid Glass) -----------------------------
  function tabbarMinimize() {
    const bar = document.getElementById("tabbar");
    if (!bar) return;
    let last = scrollY, ticking = false;
    addEventListener("scroll", () => {
      if (ticking) return; ticking = true;
      requestAnimationFrame(() => {
        const y = scrollY, dy = y - last;
        if (y < 40 || dy < -6) bar.classList.remove("mini");
        else if (dy > 6) bar.classList.add("mini");
        last = y; ticking = false;
      });
    }, { passive: true });
  }
  HA.setGlass = (v) => {
    document.documentElement.style.setProperty("--glass-tint", v);
    try { localStorage.setItem("glassTint", String(v)); } catch {}
  };

  // ---- shell ----------------------------------------------------------------------------------
  document.addEventListener("DOMContentLoaded", () => {
    connect(); tickTimes(); setInterval(tickTimes, 30000); navbar(); pullToRefresh(); tabbarMinimize();
    const more = document.getElementById("more-btn"), items = document.getElementById("more-items");
    if (more && items) more.addEventListener("click", () => HA.menu(items.innerHTML));
    HA.on((d) => { if (d.type === "heartbeat" || d.status) refreshShell(); });
    if ("serviceWorker" in navigator && (location.protocol === "https:" || ["localhost", "127.0.0.1"].includes(location.hostname))) {
      navigator.serviceWorker.register("/sw.js", { scope: "/" }).catch(() => {});
    }
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
