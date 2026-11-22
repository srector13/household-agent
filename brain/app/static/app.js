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
  document.addEventListener("visibilitychange", () => { if (!document.hidden) { HA.refreshShell && HA.refreshShell(); HA.updateBadge && HA.updateBadge(); } });

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
  HA.toast = (msg, kind = "ok", opts = {}) => {
    let box = document.querySelector(".toasts");
    if (!box) { box = document.createElement("div"); box.className = "toasts"; document.body.append(box); }
    const t = document.createElement("div");
    t.className = "toast " + kind;
    t.innerHTML = (kind === "bad" ? WARN : CHECK) + "<span></span>";
    t.querySelector("span").textContent = msg;
    const close = () => { t.classList.add("out"); setTimeout(() => t.remove(), 260); };
    if (opts.action) {
      const btn = document.createElement("button"); btn.className = "toast-act"; btn.textContent = opts.action;
      btn.onclick = (e) => { e.stopPropagation(); close(); opts.onAction && opts.onAction(); };
      t.append(btn);
    }
    box.append(t);
    t.addEventListener("click", close);
    setTimeout(close, opts.ms || (opts.action ? 6000 : kind === "bad" ? 5000 : 2600));
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

  // ---- item quick actions: done / snooze / pick a date / delete (+ undo) ---------------------------
  const enc = encodeURIComponent;
  HA.afterItemChange = () => setTimeout(() => { if (!document.querySelector(".asheet")) location.reload(); }, 650);
  function collapse(row) {
    const w = row.closest(".swipe") || row;
    w.style.height = w.offsetHeight + "px"; w.offsetHeight; // reflow
    w.classList.add("collapsing"); w.style.height = "0px";
    setTimeout(() => w.remove(), 330);
  }
  HA.item = {
    async done(row) {
      const id = row.dataset.id;
      row.classList.add("done"); const c = row.querySelector(".check"); c && c.classList.add("on");
      try {
        await HA.api("POST", `/api/items/${enc(id)}/done`, { done: true });
        HA.toast("Done", "ok", { action: "Undo", onAction: async () => {
          await HA.api("POST", `/api/items/${enc(id)}/done`, { done: false }); location.reload(); } });
        if (row.dataset.collapse !== "no") setTimeout(() => collapse(row), 380);
        HA.updateBadge && HA.updateBadge();
        document.dispatchEvent(new CustomEvent("item:done", { detail: { id, row } }));
      } catch (e) { row.classList.remove("done"); c && c.classList.remove("on"); HA.toast(e.message, "bad"); }
    },
    async snooze(row) {
      const id = row.dataset.id;
      let o;
      try { o = await HA.api("GET", `/api/items/${enc(id)}/snooze-options`); } catch (e) { return HA.toast(e.message, "bad"); }
      if (o.kind === "event") return HA.item.pick(row, o);
      const key = await HA.choose("Remind me", [...o.options.map((x) => ({ key: x.key, label: `${x.label} · ${x.sub}` })),
        { key: "_pick", label: "Pick a date & time…" }]);
      if (!key) return false;
      if (key === "_pick") return HA.item.pick(row, o);
      try {
        const d = await HA.api("POST", `/api/items/${enc(id)}/snooze`, { key });
        HA.toast(`Moved to ${d.label}`); HA.afterItemChange();
        return true;
      } catch (e) { HA.toast(e.message, "bad"); return false; }
    },
    async pick(row, o) {
      const id = row.dataset.id;
      try { o = o || await HA.api("GET", `/api/items/${enc(id)}/snooze-options`); } catch (e) { return HA.toast(e.message, "bad"); }
      const ev = o.kind === "event";
      const v = await sheet((el, done) => {
        const g = document.createElement("div"); g.className = "group pickdate";
        g.innerHTML = `<div class="msg"></div>
          ${ev ? `<label>Starts<input type="datetime-local" name="start"></label>`
               : `<label>Date<input type="date" name="due"></label><label>Time <span class="faint">optional</span><input type="time" name="due_time"></label>`}
          <button class="primary-act">Save</button>${ev ? "" : '<button class="clear destructive">Remove date</button>'}`;
        g.querySelector(".msg").textContent = o.title;
        if (ev) g.querySelector("[name=start]").value = (o.start || "").slice(0, 16);
        else {
          const t = new Date(); const local = new Date(t - t.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
          g.querySelector("[name=due]").value = o.due || local; g.querySelector("[name=due_time]").value = o.due_time || "";
        }
        g.querySelector(".primary-act").onclick = () => done(Object.fromEntries([...g.querySelectorAll("input")].map((i) => [i.name, i.value])));
        const clr = g.querySelector(".clear"); if (clr) clr.onclick = () => done({ due: null, due_time: null });
        el.append(g);
      });
      if (!v) return false;
      try {
        const d = await HA.api("POST", `/api/items/${enc(id)}/reschedule`, v);
        HA.toast(d.label === "No date" ? "Date removed" : `Moved to ${d.label}`); HA.afterItemChange();
        return true;
      } catch (e) { HA.toast(e.message, "bad"); return false; }
    },
    async remove(row) {
      const id = row.dataset.id;
      try {
        await HA.api("POST", `/api/items/${enc(id)}/delete`);
        collapse(row);
        HA.toast("Deleted", "ok", { action: "Undo", onAction: async () => {
          try { await HA.api("POST", `/api/items/${enc(id)}/restore`); HA.toast("Restored"); HA.afterItemChange(); }
          catch (e) { HA.toast(e.message, "bad"); } } });
        HA.updateBadge && HA.updateBadge();
      } catch (e) { HA.toast(e.message, "bad"); }
    },
    async menu(row) {
      const rem = row.dataset.kind !== "event";
      const opts = [];
      if (rem) opts.push({ key: "done", label: "Mark done" });
      if (rem && HA.focus) opts.push({ key: "focus", label: "Focus on this" });
      opts.push({ key: rem ? "snooze" : "pick", label: rem ? "Remind me later…" : "Move…" });
      if (rem) opts.push({ key: "pick", label: "Pick a date…" });
      opts.push({ key: "remove", label: "Delete", destructive: true });
      const k = await HA.choose(row.dataset.title || "", opts);
      if (k === "focus") HA.focus(row.dataset.id); else if (k) HA.item[k](row);
    },
  };

  // Swipe rows like Mail: right → Done, left → Later / Delete. Long-press or right-click → menu.
  function swipeable(row) {
    if (row._swipe) return; row._swipe = true;
    const rem = row.dataset.kind !== "event";
    const w = document.createElement("div"); w.className = "swipe";
    w.style.setProperty("--sep-inset", getComputedStyle(row).getPropertyValue("--sep-inset"));
    row.replaceWith(w);
    const acts = document.createElement("div"); acts.className = "swipe-acts";
    acts.innerHTML = `<div class="lead">${rem ? '<button class="sa-done">Done</button>' : ""}</div>
      <div class="trail"><button class="sa-later">${rem ? "Later" : "Move"}</button><button class="sa-del">Delete</button></div>`;
    w.append(acts, row);
    const TRAIL = 148;
    let x0 = null, y0 = 0, dx = 0, base = 0, mode = null, lp = null, moved = false;
    const set = (x, anim) => {
      row.style.transition = anim ? "transform .28s cubic-bezier(.2,.9,.3,1)" : "none";
      row.style.transform = x ? `translateX(${x}px)` : "";
      w.classList.toggle("l", x > 0); w.classList.toggle("r", x < 0);
    };
    const close = () => { base = 0; set(0, true); w.classList.remove("open"); };
    w._close = close;
    acts.querySelector(".sa-later").onclick = () => { close(); rem ? HA.item.snooze(row) : HA.item.pick(row); };
    acts.querySelector(".sa-del").onclick = () => { close(); HA.item.remove(row); };
    const dn = acts.querySelector(".sa-done"); if (dn) dn.onclick = () => { close(); HA.item.done(row); };
    row.addEventListener("pointerdown", (e) => {
      if (e.pointerType === "mouse" && e.button !== 0) return;
      if (e.target.closest("button, input, summary")) return;
      document.querySelectorAll(".swipe.open").forEach((o) => o !== w && o._close());
      x0 = e.clientX; y0 = e.clientY; dx = 0; mode = null; moved = false;
      lp = setTimeout(() => { if (!mode && x0 !== null) { moved = true; x0 = null; navigator.vibrate && navigator.vibrate(10); HA.item.menu(row); } }, 550);
    });
    row.addEventListener("pointermove", (e) => {
      if (x0 === null) return;
      const mx = e.clientX - x0, my = e.clientY - y0;
      if (!mode) {
        if (Math.abs(mx) < 8 && Math.abs(my) < 8) return;
        clearTimeout(lp);
        mode = Math.abs(mx) > Math.abs(my) * 1.2 ? "x" : "y";
        if (mode === "x") { moved = true; try { row.setPointerCapture(e.pointerId); } catch {} }
      }
      if (mode !== "x") return;
      dx = base + mx;
      if (!rem && dx > 0) dx = 0;
      if (dx > 0) dx = Math.min(dx, w.offsetWidth * .7);
      set(dx, false);
      w.classList.toggle("armed", dx > 90 || dx < -w.offsetWidth * .6);
    });
    const end = () => {
      clearTimeout(lp);
      if (mode === "x") {
        w.classList.remove("armed");
        if (dx > 90) { set(0, true); HA.item.done(row); }
        else if (dx < -w.offsetWidth * .6) { set(-w.offsetWidth, true); HA.item.remove(row); }
        else if (dx < -50) { base = -TRAIL; set(base, true); w.classList.add("open"); }
        else close();
      }
      x0 = null; mode = null;
    };
    row.addEventListener("pointerup", end); row.addEventListener("pointercancel", end);
    row.addEventListener("click", (e) => {
      if (moved || base) { e.preventDefault(); e.stopPropagation(); if (base && !moved) close(); moved = false; }
    }, true);
    row.addEventListener("contextmenu", (e) => { e.preventDefault(); clearTimeout(lp); x0 = null; HA.item.menu(row); });
  }
  HA.swipeInit = (root = document) => root.querySelectorAll("[data-swipe]").forEach(swipeable);
  document.addEventListener("pointerdown", (e) => {
    if (!e.target.closest(".swipe.open")) document.querySelectorAll(".swipe.open").forEach((o) => o._close());
  });
  document.addEventListener("DOMContentLoaded", () => HA.swipeInit());
  // "⋯" buttons inside rows
  document.addEventListener("click", (e) => {
    const b = e.target.closest("[data-item-menu]");
    if (b) { e.preventDefault(); e.stopPropagation(); HA.item.menu(b.closest("[data-swipe]")); }
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

  // ---- quick capture --------------------------------------------------------------------------
  HA.capture = () => sheet((el, done) => {
    const g = document.createElement("div"); g.className = "group capture";
    g.innerHTML = `<div class="cap-h">Capture</div>
      <textarea rows="4" placeholder="Anything on your mind — a to-do, an idea, a promise…"></textarea>
      <div class="cap-hint">Tip: tap the 🎤 on the keyboard to dictate. Several things at once is fine.</div>
      <div class="cap-actions"><button type="button" class="btn primary cap-add">Add</button></div>`;
    const ta = g.querySelector("textarea"), add = g.querySelector(".cap-add");
    const submit = async () => {
      const text = ta.value.trim(); if (!text) { ta.focus(); return; }
      HA.busy(add, true);
      try { await HA.api("POST", "/api/capture", { text }); done(true); HA.toast("Got it — sorting it out"); }
      catch (e) { HA.toast(e.message, "bad"); HA.busy(add, false); }
    };
    add.onclick = submit;
    ta.addEventListener("keydown", (e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) submit(); });
    el.append(g);
    setTimeout(() => ta.focus(), 350);
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "n" && !e.metaKey && !e.ctrlKey && !/input|textarea|select/i.test(document.activeElement.tagName)
        && !document.querySelector(".asheet")) { e.preventDefault(); HA.capture(); }
  });

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

  // ---- notifications + badge -------------------------------------------------------------------
  const b64ToBytes = (b64) => {
    const pad = "=".repeat((4 - (b64.length % 4)) % 4);
    const raw = atob((b64 + pad).replace(/-/g, "+").replace(/_/g, "/"));
    return Uint8Array.from(raw, (c) => c.charCodeAt(0));
  };
  HA.push = {
    supported: () => "serviceWorker" in navigator && "PushManager" in window && "Notification" in window,
    standalone,
    async state() {
      if (!HA.push.supported()) return "unsupported";
      if (Notification.permission === "denied") return "denied";
      const reg = await navigator.serviceWorker.getRegistration();
      const sub = reg && (await reg.pushManager.getSubscription());
      return sub ? "on" : "off";
    },
    async enable() {   // must run from a tap
      if (!HA.push.supported()) throw new Error(standalone ? "This browser can't do notifications." : "Add the app to your Home Screen first (Share → Add to Home Screen), then open it from there.");
      const perm = await Notification.requestPermission();
      if (perm !== "granted") throw new Error("Notifications weren't allowed. You can turn them on in iOS Settings → Notifications.");
      const reg = await navigator.serviceWorker.ready;
      const { public_key } = await HA.api("GET", "/api/push/key");
      let sub = await reg.pushManager.getSubscription();
      if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64ToBytes(public_key) });
      await HA.api("POST", "/api/push/subscribe", { subscription: sub.toJSON() });
      return "on";
    },
    async disable() {
      const reg = await navigator.serviceWorker.getRegistration();
      const sub = reg && (await reg.pushManager.getSubscription());
      if (sub) { await HA.api("POST", "/api/push/unsubscribe", { endpoint: sub.endpoint }); await sub.unsubscribe(); }
      return "off";
    },
  };
  async function updateBadge() {
    if (!("setAppBadge" in navigator)) return;
    try { const { count } = await HA.api("GET", "/api/badge"); count ? navigator.setAppBadge(count) : navigator.clearAppBadge(); } catch {}
  }
  HA.updateBadge = updateBadge;

  // ---- shell ----------------------------------------------------------------------------------
  document.addEventListener("DOMContentLoaded", () => {
    connect(); tickTimes(); setInterval(tickTimes, 30000); navbar(); pullToRefresh(); tabbarMinimize(); updateBadge();
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
