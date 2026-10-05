// Service worker minimo: serve solo a rendere il sito installabile come app.
// Non salva nulla in cache: ogni richiesta va sempre in rete, così i dati sono sempre aggiornati.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', e => e.respondWith(fetch(e.request)));
