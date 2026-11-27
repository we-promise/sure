import { Controller } from "@hotwired/stimulus";

// A job can answer before the browser subscribes to the suggestion's stream.
// The cable source marks itself `connected` when it subscribes: ask #show for the
// stored status then, and navigate only once the answer is final. A still-pending
// answer is replayed by the broadcast, so the waiting frame stays put. Asking the
// server means a reopened dialog never trusts a stale one-shot navigation flag.
export default class extends Controller {
  static targets = ["source", "frame"];
  static values = { url: String };

  connect() {
    this.catchUp = this.catchUp.bind(this);

    if (this.sourceTarget.hasAttribute("connected")) {
      this.catchUp();
      return;
    }

    this.observer = new MutationObserver(this.catchUp);
    this.observer.observe(this.sourceTarget, {
      attributes: true,
      attributeFilter: ["connected"],
    });
  }

  disconnect() {
    this.observer?.disconnect();
  }

  async catchUp() {
    if (!this.sourceTarget.hasAttribute("connected")) return;

    this.observer?.disconnect();
    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "application/json" },
      });
      if (!response.ok) return;

      const { status } = await response.json();
      if (["complete", "failed", "cancelled"].includes(status))
        this.frameTarget.src = this.urlValue;
    } catch {
      // A failed probe is harmless: the broadcast, or a later open, still delivers the answer.
    }
  }
}
