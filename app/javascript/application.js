// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails";
import "controllers";

Turbo.StreamActions.redirect = function () {
  // Force a full page navigation that bypasses morphing
  // This ensures stale DOM elements are cleared
  Turbo.cache.clear();
  Turbo.visit(this.target, { action: "replace" });
};

// Register service worker for PWA offline support
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/service-worker')
      .then(registration => {
        console.log('Service Worker registered with scope:', registration.scope);
      })
      .catch(error => {
        console.log('Service Worker registration failed:', error);
      });
  });
}
