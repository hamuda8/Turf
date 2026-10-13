// Registers Turf's service worker on the public pages (the app registers it in app.js): offline
// copies of visited pages, the branded offline page, and installing Turf from any page.
// Service workers exist only on https and localhost; framed embeds don't need one.
if ('serviceWorker' in navigator && window.isSecureContext && window.top === window) {
  window.addEventListener('load', () => navigator.serviceWorker.register('/sw.js', { scope: '/' }).catch(() => {}));
}
