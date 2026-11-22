/* Focus mode: one task full screen, its first step, an optional timer, and a celebration when it's done. */
(function () {
  const HA = window.HA;
  const enc = encodeURIComponent;
  const COLORS = ["#34C759", "#007AFF", "#FF9500", "#FFCC00", "#FF3B30", "#5AC8FA", "#30B0C7"];
  const ICON = {
    x: '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M18 6 6 18M6 6l12 12"/></svg>',
    check: '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>',
    step: '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 16v-2.38C4 11.5 2.97 10.5 3 8c.03-2.72 1.49-6 4.5-6C9.37 2 10 3.8 10 5.5c0 3.11-2 5.66-2 8.68V16a2 2 0 1 1-4 0Z"/><path d="M20 20v-2.38c0-2.12 1.03-3.12 1-5.62-.03-2.72-1.49-6-4.5-6C14.63 6 14 7.8 14 9.5c0 3.11 2 5.66 2 8.68V20a2 2 0 1 0 4 0Z"/></svg>',
  };
  let el = null, data = null, tick = null, wake = null;

  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const stepsKey = (id) => `focusSteps:${id}`;
  const load = (k, d) => { try { return JSON.parse(localStorage.getItem(k)) ?? d; } catch { return d; } };
  const save = (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} };

  async function keepAwake(on) {
    try {
      if (on && "wakeLock" in navigator && !wake) wake = await navigator.wakeLock.request("screen");
      if (!on && wake) { await wake.release(); wake = null; }
    } catch {}
  }

  function close() {
    if (!el) return;
    clearInterval(tick); keepAwake(false);
    el.classList.remove("show"); const e = el; el = null;
    setTimeout(() => e.remove(), 300);
    document.documentElement.classList.remove("focusing");
    if (new URLSearchParams(location.search).has("focus")) history.replaceState(null, "", location.pathname);
  }

  function render() {
    const d = data, done = load(stepsKey(d.item_id), []);
    const t = d.timer;
    el.querySelector(".fx-body").innerHTML = `
      <div class="fx-kicker">${d.category === "promise" ? "🤝 You promised " + esc(d.person) : d.category === "waiting" ? "⏳ Follow up with " + esc(d.person) : d.person ? "From " + esc(d.person) : "Focus on one thing"}</div>
      <h1 class="fx-title">${esc(d.title)}</h1>
      ${d.context ? `<div class="fx-context">${esc(d.context)}</div>` : ""}
      ${d.first_step ? `<div class="fx-start"><span class="fx-ic">${ICON.step}</span><div><b>Start here</b><div>${esc(d.first_step)}</div></div></div>`
        : `<button class="fx-findstep">${ICON.step} Find a tiny first step</button>`}
      ${d.steps && d.steps.length ? `<div class="fx-steps">${d.steps.map((s, i) => `<button class="fx-step ${done.includes(i) ? "on" : ""}" data-i="${i}"><span class="box">${ICON.check}</span><span>${esc(s)}</span></button>`).join("")}</div>` : ""}
      <div class="fx-timer ${t ? "running" : ""}">
        <svg class="ring" viewBox="0 0 120 120"><circle cx="60" cy="60" r="52" class="track"/><circle cx="60" cy="60" r="52" class="prog"/></svg>
        <div class="fx-time"><b>${t ? "" : "10:00"}</b><span>${t ? "focus" : "minutes"}</span></div>
      </div>
      <div class="fx-tctl">${t
        ? `<button class="chip" data-add="5">+5 min</button><button class="chip" data-stop>Stop timer</button>`
        : [5, 10, 25].map((m) => `<button class="chip ${m === 10 ? "on" : ""}" data-min="${m}">${m} min</button>`).join("") + `<button class="chip go" data-go>Start timer</button>`}</div>`;
    el.querySelector(".fx-next").innerHTML = "";
    bind();
    runTimer();
  }

  function bind() {
    const b = el.querySelector(".fx-body");
    b.querySelectorAll(".fx-step").forEach((s) => s.onclick = () => {
      const i = +s.dataset.i, k = stepsKey(data.item_id), cur = load(k, []);
      const on = !cur.includes(i); save(k, on ? [...cur, i] : cur.filter((x) => x !== i));
      s.classList.toggle("on", on); if (on) burst(s, 14);
    });
    const fs = b.querySelector(".fx-findstep");
    if (fs) fs.onclick = async () => {
      HA.busy(fs, true);
      try { const r = await HA.api("POST", `/api/items/${enc(data.item_id)}/breakdown`); data.first_step = r.first_step; data.steps = r.steps; render(); }
      catch (e) { HA.toast(e.message, "bad"); HA.busy(fs, false); }
    };
    let minutes = 10;
    b.querySelectorAll("[data-min]").forEach((c) => c.onclick = () => {
      minutes = +c.dataset.min; b.querySelectorAll("[data-min]").forEach((x) => x.classList.toggle("on", x === c));
      b.querySelector(".fx-time b").textContent = `${minutes}:00`;
    });
    const go = b.querySelector("[data-go]");
    if (go) go.onclick = () => startTimer(minutes);
    const add = b.querySelector("[data-add]");
    if (add) add.onclick = () => {
      const left = Math.max(0, (new Date(data.timer.ends_at) - Date.now()) / 60000);
      startTimer(Math.round(left + 5));
    };
    const stop = b.querySelector("[data-stop]");
    if (stop) stop.onclick = async () => { await HA.api("POST", "/api/focus/timer", { stop: true }); data.timer = null; render(); };
  }

  async function startTimer(minutes) {
    try {
      const r = await HA.api("POST", "/api/focus/timer", { item_id: data.item_id, minutes });
      data.timer = r.timer; render();
      if (HA.push && HA.push.state && (await HA.push.state()) !== "on") HA.toast("Tip: turn on notifications in Settings to get a nudge when time's up");
    } catch (e) { HA.toast(e.message, "bad"); }
  }

  function runTimer() {
    clearInterval(tick);
    const t = data.timer; if (!t || !el) return;
    const total = t.minutes * 60000, end = new Date(t.ends_at).getTime();
    const prog = el.querySelector(".prog"), label = el.querySelector(".fx-time b"), sub = el.querySelector(".fx-time span");
    const C = 2 * Math.PI * 52; prog.style.strokeDasharray = C;
    const step = () => {
      const left = Math.max(0, end - Date.now());
      prog.style.strokeDashoffset = C * (1 - left / total);
      const s = Math.ceil(left / 1000);
      label.textContent = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
      if (left <= 0) {
        clearInterval(tick); sub.textContent = "time's up";
        el.querySelector(".fx-timer").classList.add("up");
        chime(); navigator.vibrate && navigator.vibrate([120, 80, 120]);
        el.querySelector(".fx-next").innerHTML = `<div class="fx-up">Nice work. Done, or keep going?</div>`;
      }
    };
    step(); tick = setInterval(step, 500);
  }

  function chime() {
    try {
      const a = new (window.AudioContext || window.webkitAudioContext)();
      [660, 880].forEach((f, i) => {
        const o = a.createOscillator(), g = a.createGain(); o.frequency.value = f; o.type = "sine";
        g.gain.setValueAtTime(0.0001, a.currentTime + i * 0.18);
        g.gain.exponentialRampToValueAtTime(0.25, a.currentTime + i * 0.18 + 0.02);
        g.gain.exponentialRampToValueAtTime(0.0001, a.currentTime + i * 0.18 + 0.6);
        o.connect(g).connect(a.destination); o.start(a.currentTime + i * 0.18); o.stop(a.currentTime + i * 0.18 + 0.7);
      });
    } catch {}
  }

  // confetti from an element (or the middle of the screen)
  function burst(from, n = 90) {
    const r = from ? from.getBoundingClientRect() : { left: innerWidth / 2, top: innerHeight / 2, width: 0, height: 0 };
    const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    const c = document.createElement("canvas"); c.className = "confetti";
    c.width = innerWidth * devicePixelRatio; c.height = innerHeight * devicePixelRatio;
    document.body.append(c);
    const g = c.getContext("2d"); g.scale(devicePixelRatio, devicePixelRatio);
    const ps = Array.from({ length: n }, () => {
      const a = Math.random() * Math.PI * 2, v = (n > 30 ? 6 : 3.5) + Math.random() * (n > 30 ? 9 : 4);
      return { x: cx, y: cy, vx: Math.cos(a) * v, vy: Math.sin(a) * v - (n > 30 ? 6 : 2), r: Math.random() * 6.28, vr: (Math.random() - .5) * .4,
        w: 6 + Math.random() * 6, h: 3 + Math.random() * 5, col: COLORS[(Math.random() * COLORS.length) | 0] };
    });
    let f = 0;
    const frame = () => {
      g.clearRect(0, 0, innerWidth, innerHeight);
      ps.forEach((p) => { p.vy += .32; p.vx *= .985; p.x += p.vx; p.y += p.vy; p.r += p.vr;
        g.save(); g.translate(p.x, p.y); g.rotate(p.r); g.globalAlpha = Math.max(0, 1 - f / 110); g.fillStyle = p.col; g.fillRect(-p.w / 2, -p.h / 2, p.w, p.h); g.restore(); });
      if (++f < 120) requestAnimationFrame(frame); else c.remove();
    };
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) { c.remove(); return; }
    requestAnimationFrame(frame);
  }
  HA.confetti = burst;

  async function finish(btn) {
    HA.busy(btn, true);
    try {
      await HA.api("POST", `/api/items/${enc(data.item_id)}/done`, { done: true });
      if (data.timer) await HA.api("POST", "/api/focus/timer", { stop: true }).catch(() => {});
      clearInterval(tick); data.timer = null;
      el.classList.add("celebrate");
      burst(btn);
      navigator.vibrate && navigator.vibrate([30, 40, 60]);
      const n = data.next;
      el.querySelector(".fx-body").innerHTML = `
        <div class="fx-done"><div class="fx-bigcheck">${ICON.check}</div><h1>Done!</h1><p>“${esc(data.title)}” is off your plate.</p></div>`;
      el.querySelector(".fx-foot").innerHTML = n
        ? `<div class="fx-nextcard"><span>Next up · ${esc(n.why)}</span><b>${esc(n.title)}</b></div>
           <button class="fx-main" data-next="${esc(n.item_id)}">Focus on it</button><button class="fx-sec" data-close>Take a break</button>`
        : `<button class="fx-main" data-close>Back to my day</button>`;
      el.querySelector(".fx-next").innerHTML = "";
      el.querySelectorAll("[data-close]").forEach((b) => b.onclick = () => { close(); location.reload(); });
      const nb = el.querySelector("[data-next]"); if (nb) nb.onclick = () => open(nb.dataset.next);
      HA.updateBadge && HA.updateBadge();
    } catch (e) { HA.toast(e.message, "bad"); HA.busy(btn, false); }
  }

  async function open(id) {
    let d;
    try { d = await HA.api("GET", `/api/focus/${enc(id)}`); } catch (e) { return HA.toast(e.message, "bad"); }
    if (!["planned", "active"].includes(d.status)) return HA.toast("That one's already finished");
    data = d;
    if (!el) {
      el = document.createElement("div"); el.className = "focus"; el.setAttribute("role", "dialog"); el.setAttribute("aria-label", "Focus mode");
      document.body.append(el);
      requestAnimationFrame(() => el.classList.add("show"));
      document.documentElement.classList.add("focusing");
    }
    el.classList.remove("celebrate");
    el.innerHTML = `<div class="fx-top"><button class="fx-x" aria-label="Close">${ICON.x}</button><span>Focus</span><span style="width:40px"></span></div>
      <div class="fx-body"></div><div class="fx-next"></div>
      <div class="fx-foot"><button class="fx-main fx-done-btn">${ICON.check} Done</button><button class="fx-sec" data-later>Not now</button></div>`;
    el.querySelector(".fx-x").onclick = close;
    el.querySelector(".fx-done-btn").onclick = (e) => finish(e.currentTarget);
    el.querySelector("[data-later]").onclick = close;
    keepAwake(true);
    render();
  }
  HA.focus = open;

  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && el) close(); });
  document.addEventListener("visibilitychange", () => { if (!document.hidden && el && data && data.timer) runTimer(); });
  const q = new URLSearchParams(location.search).get("focus");
  if (q) document.addEventListener("DOMContentLoaded", () => open(q));
})();
