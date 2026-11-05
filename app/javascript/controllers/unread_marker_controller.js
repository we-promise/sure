import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="unread-marker"
// Marks the listed transactions read once the page is actually displayed.
// Rendered only on responses to Turbo hover-prefetches, which the server
// cannot mark read itself because the user may never open them.
export default class extends Controller {
  static values = { url: String, entryIds: Array };

  connect() {
    if (this.entryIdsValue.length === 0) return;

    const csrfToken = document.querySelector('meta[name="csrf-token"]');

    const body = new FormData();
    for (const id of this.entryIdsValue) body.append("entry_ids[]", id);

    fetch(this.urlValue, {
      method: "POST",
      headers: csrfToken ? { "X-CSRF-Token": csrfToken.content } : {},
      body,
      keepalive: true,
    }).catch(() => {
      // Best effort: the rows stay unread and are marked on the next visit.
    });
  }
}
