// Service worker: rende il sito installabile come app e riceve le notifiche.
// Non salva nulla in cache: ogni richiesta va sempre in rete, così i dati sono sempre aggiornati.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', e => e.respondWith(fetch(e.request)));

// Arriva una notifica dalla funzione «notifiche» su Supabase
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { body: e.data ? e.data.text() : '' }; }
  const title = d.title || 'Pro Albettone';
  // numerino sull'icona: lo stesso conteggio dei pallini gialli del sito, calcolato al momento dell'invio
  const setBadge = () => {
    try {
      const nav = self.navigator;
      if (typeof d.badge !== 'number' || !nav || !('setAppBadge' in nav)) return Promise.resolve();
      return (d.badge > 0 ? nav.setAppBadge(d.badge) : nav.clearAppBadge()).catch(() => {});
    } catch (err) { return Promise.resolve(); }
  };
  e.waitUntil(Promise.all([setBadge(), self.registration.showNotification(title, {
    body: d.body || '',
    icon: 'icon.png',
    badge: 'icon.png',
    tag: d.tag || undefined,       // avvisi con lo stesso tag si sostituiscono (es. promemoria della stessa partita)
    renotify: !!d.tag,
    data: { url: d.url || './' }
  })]));
});

// Tocco sulla notifica: apre l'app (o la porta in primo piano) sulla pagina giusta
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || './', self.registration.scope).href;
  e.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of all) {
      if (c.url.startsWith(self.registration.scope)) {
        try { await c.focus(); } catch (err) {}
        try { return await c.navigate(url); } catch (err) { c.postMessage({ goto: url }); return; }
      }
    }
    return self.clients.openWindow(url);
  })());
});
