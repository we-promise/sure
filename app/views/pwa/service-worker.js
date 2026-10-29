const CACHE_VERSION = 'v1';
const OFFLINE_ASSETS = [
  '/offline.html',
  '/logo-offline.svg'
];

// Install event - cache the offline page and assets
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_VERSION).then((cache) => {
      return cache.addAll(OFFLINE_ASSETS);
    })
  );
  // Activate immediately
  self.skipWaiting();
});

// Activate event - clean up old caches
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((cacheNames) => {
      return Promise.all(
        cacheNames.map((cacheName) => {
          if (cacheName !== CACHE_VERSION) {
            return caches.delete(cacheName);
          }
        })
      );
    }).then(() => {
      // Take control of all pages immediately
      return self.clients.claim();
    })
  );
});

// Fetch event - serve offline page when network fails
self.addEventListener('fetch', (event) => {
  // Handle navigation requests (page loads)
  if (event.request.mode === 'navigate') {
    event.respondWith(
      fetch(event.request).catch((error) => {
        // Only show offline page for network errors
        if (error.name === 'TypeError' || !navigator.onLine) {
          return caches.match('/offline.html');
        }
        throw error;
      })
    );
  }
  // Handle offline assets (logo, etc.)
  else if (OFFLINE_ASSETS.some(asset => new URL(event.request.url).pathname === asset)) {
    event.respondWith(
      caches.match(event.request).then((response) => {
        return response || fetch(event.request);
      })
    );
  }
});

// Only notification links into the insight feed are accepted. Provider payloads
// never grant an arbitrary URL permission to open or navigate a browser window.
function insightNotificationPath(value) {
  try {
    const url = new URL(value, self.location.origin);
    if (url.origin === self.location.origin && url.pathname === "/insights") {
      const anchor = /^#insight_[0-9a-f-]{36}$/i.test(url.hash) ? url.hash : "";
      return `/insights${anchor}`;
    }
  } catch {
    // A malformed or absent destination returns to the feed.
  }
  return "/insights";
}

self.addEventListener("push", (event) => {
  let payload = {};
  try {
    const data = event.data?.json();
    if (data && typeof data === "object") payload = data;
  } catch {
    // Even an empty or malformed push must display a visible notification.
  }

  event.waitUntil(
    self.registration.showNotification("Sure", {
      body: typeof payload.body === "string" ? payload.body : "",
      icon: "/logo-offline.svg",
      tag: typeof payload.tag === "string" ? payload.tag : "sure-financial-alert",
      data: { path: insightNotificationPath(payload.data?.path) },
    }),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const path = insightNotificationPath(event.notification.data?.path);
  const destination = new URL(path, self.location.origin);

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(async (windows) => {
      for (const client of windows) {
        const url = new URL(client.url);
        if (url.origin === destination.origin && url.pathname === destination.pathname && "focus" in client) {
          if ("navigate" in client) await client.navigate(destination.href);
          return client.focus();
        }
      }
      return self.clients.openWindow(destination.href);
    }),
  );
});
