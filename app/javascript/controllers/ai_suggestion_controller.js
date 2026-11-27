import { Controller } from "@hotwired/stimulus";

// A job can answer before the browser subscribes to the suggestion's stream.
// The cable source marks itself `connected` when it subscribes: navigate the
// waiting frame to #show once on that transition, so the stored result is read
// in a request with a valid token. The flag lives in session storage because
// the frame is replaced by the response, which may still be a waiting frame.
export default class extends Controller {
  static targets = ["source", "frame"];
  static values = { url: String, key: String };

  connect() {
    this.navigate = this.navigate.bind(this);

    if (this.navigated) return;

    if (this.sourceTarget.hasAttribute("connected")) {
      this.navigate();
      return;
    }

    this.observer = new MutationObserver(this.navigate);
    this.observer.observe(this.sourceTarget, {
      attributes: true,
      attributeFilter: ["connected"],
    });
  }

  disconnect() {
    this.observer?.disconnect();
  }

  navigate() {
    if (this.navigated) return;

    this.markNavigated();
    this.observer?.disconnect();
    this.frameTarget.src = this.urlValue;
  }

  get navigated() {
    try {
      return sessionStorage.getItem(this.keyValue) === "1";
    } catch {
      return false;
    }
  }

  markNavigated() {
    try {
      sessionStorage.setItem(this.keyValue, "1");
    } catch {
      // A browser with storage disabled still gets one navigation per controller.
    }
  }
}
