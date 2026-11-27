import { Controller } from "@hotwired/stimulus";

// Focusing or typing in the chat box holds back background AI jobs
// (ChatReservation), pinging at most every 5 s.
export default class extends Controller {
  static targets = ["bubble", "countdown"];
  static values = { url: String };

  disconnect() {
    clearInterval(this.timer);
  }

  hold() {
    if (Date.now() - (this.lastPingAt || 0) < 5000) return;
    this.lastPingAt = Date.now();

    fetch(this.urlValue, {
      method: "POST",
      headers: {
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
        Accept: "text/vnd.turbo-stream.html",
      },
    })
      .then((response) => (response.ok ? response.text() : ""))
      .then((html) => html && Turbo.renderStreamMessage(html))
      .catch(() => {});
  }

  hide() {
    clearInterval(this.timer);
    if (this.hasBubbleTarget) this.bubbleTarget.remove();
  }

  bubbleTargetConnected(bubble) {
    clearInterval(this.timer);
    this.endsAt = Date.now() + Number(bubble.dataset.seconds) * 1000;
    this.#tick();
    this.timer = setInterval(() => this.#tick(), 1000);
  }

  #tick() {
    const seconds = Math.ceil((this.endsAt - Date.now()) / 1000);
    if (seconds <= 0 || !this.hasBubbleTarget) return this.hide();
    if (this.hasCountdownTarget) this.countdownTarget.textContent = seconds;
  }
}
