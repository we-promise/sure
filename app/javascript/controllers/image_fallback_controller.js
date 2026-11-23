import { Controller } from "@hotwired/stimulus";

// Removes an <img> the browser cannot load, revealing the fallback rendered
// underneath it. This replaces an inline onerror handler, which the
// Content-Security-Policy blocks.
export default class extends Controller {
  static values = { retry: Boolean, releasePermanent: Boolean };

  connect() {
    // The image may have failed before Stimulus connected, in which case its
    // error event is already gone. decode() rejects for a broken image and
    // resolves for one that loaded (including SVGs without a natural size).
    if (this.element.complete) {
      this.element.decode().catch(() => this.remove());
    }
  }

  remove() {
    if (this.retryValue && this.#retryOnce()) return;

    // A logo in a wrapper Turbo carries across visits must not be carried as
    // its initials, so the wrapper drops its permanence and the next page
    // tries the image again.
    if (this.releasePermanentValue) {
      this.element
        .closest("[data-turbo-permanent]")
        ?.removeAttribute("data-turbo-permanent");
    }
    this.element.remove();
  }

  // iOS Safari can fail an image it only revalidated (its cached redirect,
  // then 304 Not Modified, with the cached copy already dropped). A fresh URL
  // makes it fetch a same-origin image again rather than give up on it.
  #retryOnce() {
    const image = this.element;
    if (image.dataset.retried) return false;

    const url = new URL(image.src);
    if (url.origin !== window.location.origin) return false;

    image.dataset.retried = "1";
    url.searchParams.set("retry", Date.now());
    image.src = url.toString();
    return true;
  }
}
