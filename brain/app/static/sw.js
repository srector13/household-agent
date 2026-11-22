/* Second Brain service worker — v__VERSION__
 * Static assets: cache-first. Pages: network-first, falling back to the last copy (or /offline).
 * /api/* (JSON, the live SSE stream) and every non-GET request always go to the network. */
const VERSION = "__VERSION__";
const STATIC = `ha-static-${VERSION}`;
const PAGES = `ha-pages-${VERSION}`;
const SHELL = [
  `/static/app.css?v=${VERSION}`, `/static/app.js?v=${VERSION}`, `/static/focus.js?v=${VERSION}`, "/offline",
  "/static/icons/icon-192.png", "/static/icons/apple-touch-icon.png", "/static/icons/favicon-32.png",
];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(STATIC).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => ![STATIC, PAGES].includes(k)).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (e) => {
  const req = e.request;
  const url = new URL(req.url);
  if (req.method !== "GET" || url.origin !== location.origin) return;
  if (url.pathname.startsWith("/api/") || url.pathname === "/sw.js") return;

  if (url.pathname.startsWith("/static/")) {
    e.respondWith(caches.match(req).then((hit) => hit || fetch(req).then((res) => {
      if (res.ok) { const copy = res.clone(); caches.open(STATIC).then((c) => c.put(req, copy)); }
      return res;
    })));
    return;
  }

  if (req.mode === "navigate" || (req.headers.get("accept") || "").includes("text/html")) {
    e.respondWith(
      fetch(req).then((res) => {
        if (res.ok && !url.pathname.startsWith("/partials/")) {
          const copy = res.clone();
          caches.open(PAGES).then((c) => c.put(req, copy));
        }
        return res;
      }).catch(async () => (await caches.match(req)) || (await caches.match("/offline")))
    );
  }
});

// ---- push notifications + app-icon badge ------------------------------------------------------
self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = { title: "Second Brain", body: e.data ? e.data.text() : "" }; }
  const jobs = [self.registration.showNotification(d.title || "Second Brain", {
    body: d.body || "", tag: d.tag || undefined, data: { url: d.url || "/" },
    icon: "/static/icons/icon-192.png", badge: "/static/icons/icon-192.png",
  })];
  if (typeof d.badge === "number" && self.navigator && "setAppBadge" in self.navigator) {
    jobs.push(d.badge > 0 ? self.navigator.setAppBadge(d.badge) : self.navigator.clearAppBadge());
  }
  e.waitUntil(Promise.all(jobs).catch(() => {}));
});

self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || "/";
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((wins) => {
    for (const w of wins) {
      if ("focus" in w) { if ("navigate" in w) w.navigate(url).catch(() => {}); return w.focus(); }
    }
    return self.clients.openWindow(url);
  }));
});
