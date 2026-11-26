import { Controller } from "@hotwired/stimulus";

// A job can answer before the browser subscribes to the suggestion's stream.
// The cable source marks itself `connected` when it subscribes: reload the
// frame once on that transition. `show` renders whatever the row holds, so a
// reload is always right, whether the answer arrived before or after us.
export default class extends Controller {
  static targets = ["source", "frame"];

  connect() {
    this.reload = this.reload.bind(this);

    if (this.sourceTarget.hasAttribute("connected")) {
      this.reload();
      return;
    }

    this.observer = new MutationObserver(this.reload);
    this.observer.observe(this.sourceTarget, {
      attributes: true,
      attributeFilter: ["connected"],
    });
  }

  disconnect() {
    this.observer?.disconnect();
  }

  reload() {
    if (this.reloaded) return;
    this.reloaded = true;
    this.observer?.disconnect();
    this.frameTarget.reload();
  }
}
