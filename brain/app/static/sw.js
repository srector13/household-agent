/* Second Brain service worker — v__VERSION__
 * Static assets: cache-first. Pages: network-first, falling back to the last copy (or /offline).
 * /api/* (JSON, the live SSE stream) and every non-GET request always go to the network. */
const VERSION = "__VERSION__";
const STATIC = `ha-static-${VERSION}`;
const PAGES = `ha-pages-${VERSION}`;
const SHELL = [
  `/static/app.css?v=${VERSION}`, `/static/app.js?v=${VERSION}`, "/offline",
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
