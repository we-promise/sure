// Rewrites the current history entry's URL the way a Turbo "replace" visit
// does, minus the request. A raw history.replaceState hides the new URL from
// Turbo. With other state, Turbo ignores Back to the entry. With Turbo's state
// kept, Turbo still caches the page under the old URL, so Back to the new one
// refetches the page instead of restoring it.
//
// Uses Turbo 8.0.13 internals, like the turbo:load listener in application.js.
// test/system/replace_url_back_test.rb fails if an upgrade moves them.
export default function replaceUrl(url) {
  const location = new URL(url, window.location.href);
  const { session } = Turbo;

  session.history.replace(location, session.history.restorationIdentifier);
  session.view.lastRenderedLocation = location;
}
