// Let's Walk service worker.
// Pages: network first (so updates arrive right away), cached copy when offline.
// Own icons and manifest: cache first. Other sites (map tiles, Supabase, CDNs) are not touched.
const CACHE = "lets-walk-v3";
const SHELL = ["./", "./index.html", "./manifest.webmanifest", "./assets/logo/icon-192.png", "./assets/logo/icon-512.png"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  if (req.mode === "navigate") {
    e.respondWith(
      fetch(req)
        .then(res => { const copy = res.clone(); caches.open(CACHE).then(c => c.put("./index.html", copy)); return res; })
        .catch(() => caches.match("./index.html"))
    );
    return;
  }

  e.respondWith(
    caches.match(req).then(hit => hit || fetch(req).then(res => {
      if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(req, copy)); }
      return res;
    }))
  );
});

// ---------- push notifications ----------
self.addEventListener("push", e => {
  let m = {};
  try { m = e.data ? e.data.json() : {}; } catch (_) { m = { body: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(m.title || "Let's Walk", {
    body: m.body || "",
    icon: "./assets/logo/icon-192.png",
    badge: "./assets/logo/icon-192.png",
    tag: m.tag || undefined,
    renotify: !!m.tag,
    silent: false,
    vibrate: [120, 60, 120],
    timestamp: Date.now(),
    data: { url: m.url || "./" }
  }));
});

self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || "./";
  e.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of all) {
      if (c.url.startsWith(self.registration.scope)) {
        await c.focus();
        try { await c.navigate(url); } catch (_) { c.postMessage({ open: url }); }
        return;
      }
    }
    await self.clients.openWindow(url);
  })());
});
