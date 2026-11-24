// package-flutter-web.py replaces these two values in production builds.
const CACHE = 'meethalfway-shell-development';
const SHELL = [];
const RUNTIME = 'meethalfway-ai-runtime-v1';
self.addEventListener('install', event => event.waitUntil(
  // Bypass the HTTP cache so a new worker never stores the previous build's files.
  caches.open(CACHE).then(cache => cache.addAll(SHELL.map(url => new Request(url, {cache: 'reload'}))))
    .then(() => self.skipWaiting())
));
self.addEventListener('activate', event => event.waitUntil(
  caches.keys().then(keys => Promise.all(keys.filter(key =>
    key.startsWith('meethalfway-') && key !== CACHE && key !== RUNTIME
  ).map(key => caches.delete(key)))).then(() => self.clients.claim())
));
self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (request.mode === 'navigate' && url.origin === self.location.origin) {
    event.respondWith(fetch(request).then(response => {
      if (response.ok) { const copy = response.clone(); caches.open(CACHE).then(c => c.put('index.html', copy)); }
      return response;
    }).catch(() => caches.match('index.html')));
  } else if (url.origin === self.location.origin && SHELL.includes(url.pathname.replace(/^\//, ''))) {
    event.respondWith(caches.match(request).then(cached => cached || fetch(request)));
  } else if (url.hostname === 'cdn.jsdelivr.net' && url.pathname.includes('@litert-lm/')) {
    // Only public engine assets; never cache authentication or model prompts.
    event.respondWith(caches.open(RUNTIME).then(async cache => {
      const cached = await cache.match(request);
      if (cached) return cached;
      const response = await fetch(request);
      if (response.ok) await cache.put(request, response.clone());
      return response;
    }));
  }
});
