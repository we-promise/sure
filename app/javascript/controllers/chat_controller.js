import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["messages", "form", "input", "submit", "pendingResponse"];
  static values = {
    // How long a pending "Thinking…" bubble may wait before we assume the
    // background worker never delivered a response. Generous so slow models or
    // tool calls don't trip it.
    responseTimeout: { type: Number, default: 90000 },
    // How often to re-check pending bubbles.
    pollInterval: { type: Number, default: 5000 },
  };

  connect() {
    this.reportedUrls = new Set();
    this.inFlightUrls = new Set();
    this.#configureAutoScroll();
    this.#updateSubmitState();
    this.#startUndeliveredWatchdog();
  }

  disconnect() {
    if (this.messagesObserver) {
      this.messagesObserver.disconnect();
    }
    if (this.watchdogTimer) {
      clearInterval(this.watchdogTimer);
    }
  }

  autoResize() {
    const input = this.inputTarget;
    const lineHeight = 20; // text-sm line-height (14px * 1.429 ≈ 20px)
    const maxLines = 3; // 3 lines = 60px total

    input.style.height = "auto";
    input.style.height = `${Math.min(input.scrollHeight, lineHeight * maxLines)}px`;
    input.style.overflowY =
      input.scrollHeight > lineHeight * maxLines ? "auto" : "hidden";

    this.#updateSubmitState();
  }

  submitSampleQuestion(e) {
    this.inputTarget.value = e.target.dataset.chatQuestionParam;
    this.#updateSubmitState();

    setTimeout(() => {
      this.formTarget.requestSubmit();
    }, 200);
  }

  // Newlines require shift+enter, otherwise submit the form (same functionality as ChatGPT and others)
  handleInputKeyDown(e) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      if (this.#hasContent()) {
        this.formTarget.requestSubmit();
      }
    }
  }

  #hasContent() {
    return this.inputTarget.value.trim().length > 0;
  }

  #updateSubmitState() {
    if (!this.hasSubmitTarget) return;
    this.submitTarget.disabled = !this.#hasContent();
  }

  #configureAutoScroll() {
    this.messagesObserver = new MutationObserver((_mutations) => {
      if (this.hasMessagesTarget) {
        this.#scrollToBottom();
      }
    });

    // Listen to entire sidebar for changes, always try to scroll to the bottom
    this.messagesObserver.observe(this.element, {
      childList: true,
      subtree: true,
    });
  }

  #scrollToBottom = () => {
    this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight;
  };

  // Watchdog: a "Thinking…" bubble only resolves when the background worker
  // streams a response over Turbo. If the worker is down — or the job dies
  // before it can broadcast an error — the bubble would otherwise spin forever
  // with no feedback. We detect a pending bubble that has waited past the
  // threshold and ask the server to mark it failed, so the user gets an error
  // message + Retry instead of a dead spinner.
  //
  // We key off the pending marker itself (it only exists while pending and
  // disappears the instant a real response renders) rather than a status flag,
  // so a response that starts streaming can never be falsely timed out.
  #startUndeliveredWatchdog() {
    this.#checkUndeliveredResponses();
    this.watchdogTimer = setInterval(() => {
      this.#checkUndeliveredResponses();
    }, this.pollIntervalValue);
  }

  #checkUndeliveredResponses() {
    if (!this.hasPendingResponseTarget) return;

    const now = Date.now();

    this.pendingResponseTargets.forEach((el) => {
      const url = el.dataset.pendingResponseTimeoutUrl;
      // Skip if already reported (succeeded) or a report is in flight.
      if (!url || this.reportedUrls.has(url) || this.inFlightUrls.has(url)) return;

      const createdAt = Date.parse(el.dataset.pendingResponseCreatedAt);
      if (Number.isNaN(createdAt)) return;
      if (now - createdAt < this.responseTimeoutValue) return;

      this.#reportUndelivered(url);
    });
  }

  #reportUndelivered(url) {
    const token = document.querySelector('meta[name="csrf-token"]')?.content;

    this.inFlightUrls.add(url);

    fetch(url, {
      method: "POST",
      headers: {
        "X-CSRF-Token": token || "",
        Accept: "text/vnd.turbo-stream.html, text/html",
      },
      credentials: "same-origin",
    })
      .then((response) => {
        // Only mark as reported on success. fetch resolves on HTTP 4xx/5xx
        // (it rejects only on network errors), so without this check a failed
        // POST would permanently suppress retries and strand the bubble.
        if (response.ok) this.reportedUrls.add(url);
      })
      .catch(() => {
        // Best-effort. Leave the URL un-reported so the next tick can retry.
      })
      .finally(() => {
        this.inFlightUrls.delete(url);
      });
  }
}
