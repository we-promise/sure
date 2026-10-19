import { Controller } from "@hotwired/stimulus";

// A drawer or modal over the page, or a frame that may still be fetching one.
// Any loading frame counts, not just #drawer and #modal: dialogs also arrive
// in frames of their own, such as the transactions bulk-edit drawer, and
// listing frame ids would miss the next one.
const COVERED = "dialog:modal, turbo-frame[busy]";

// "What's new" release highlight.
//
// Shows the deployed release's notes once per account:
//   1. waits for the first real pointer/keyboard interaction after page load
//      (so the popup never interrupts the initial render, and the PWA only
//      pops it once the user is actually engaging),
//   2. fetches the release notes for the pending tag (no notes = no popup),
//   3. opens them in a DS::Dialog once no drawer or modal covers the page,
//   4. marks the release tag as seen server-side when the user dismisses it
//      (Done, Close, Escape or a click outside: anything that closes it).
//
// Navigating away without dismissing is not "seen": the dialog is removed
// quietly and the next page offers it again. A window-level flag keyed to the
// tag prevents double-shows across Turbo reconnects, cached page restores,
// and duplicate mounts.
export default class extends Controller {
  static values = {
    contentUrl: String,
    dismissUrl: String,
    tag: String,
  };

  connect() {
    if (this.shownTag() === this.tagValue) return;

    this.handleFirstInteraction = this.handleFirstInteraction.bind(this);
    window.addEventListener("pointerdown", this.handleFirstInteraction, {
      capture: true,
      once: true,
    });
    window.addEventListener("keydown", this.handleFirstInteraction, {
      capture: true,
      once: true,
    });
  }

  disconnect() {
    this.removeInteractionListeners();
    window.clearTimeout(this.showTimeout);
    this.stopWaiting();
    this.fetchAbort?.abort();

    // Removed for navigation, not closed by the user: not seen. Removing an
    // open dialog fires no close event.
    this.removeDialog();

    if (!this.dismissed) this.releaseShownFlag();
  }

  handleFirstInteraction() {
    // Another mount already claimed this tag (Turbo reconnect, duplicate).
    if (this.shownTag() === this.tagValue) return;

    this.shownFlagToken = Symbol(this.tagValue);
    window.__releaseHighlightShownTag = {
      tag: this.tagValue,
      token: this.shownFlagToken,
    };
    this.removeInteractionListeners();

    // Let the triggering interaction land before the dialog takes over; if
    // it started a navigation, disconnect() cancels this before it shows.
    this.showTimeout = window.setTimeout(() => this.show(), 150);
  }

  async show() {
    const notesHtml = await this.fetchNotes();

    // No notes (or gone again): release the flag so a later page can retry.
    if (!notesHtml) {
      this.releaseShownFlag();
      return;
    }

    // Gone while the notes loaded (Turbo swapped the page): don't open.
    if (this.notesHtml || !this.element.isConnected) return;
    this.notesHtml = notesHtml;
    this.openWhenUncovered();
  }

  // That first click is often the one that opens a drawer or a modal. Opening
  // this over it would cut it short, so it waits for the page to be clear.
  // Polled rather than waiting for a close event: a dialog can also leave
  // with its frame, without one.
  openWhenUncovered() {
    if (document.querySelector(COVERED)) {
      this.uncoveredPoll ??= window.setInterval(
        () => this.openWhenUncovered(),
        250,
      );
      return;
    }

    this.stopWaiting();

    const template = document.createElement("template");
    template.innerHTML = this.notesHtml;
    this.dialogWrapper = template.content.firstElementChild;
    // Kept out of Turbo's page cache, or Back would bring it back.
    this.dialogWrapper.dataset.turboTemporary = "";
    this.dialogWrapper
      .querySelector("dialog")
      .addEventListener("close", () => this.dismiss(), { once: true });
    // On <body>, not in this element: a modal dialog inside a hidden
    // ancestor blocks the page without showing.
    document.body.append(this.dialogWrapper);
  }

  stopWaiting() {
    window.clearInterval(this.uncoveredPoll);
    this.uncoveredPoll = null;
  }

  dismiss() {
    this.dismissed = true;
    this.removeDialog();
    this.markSeen();
  }

  removeDialog() {
    this.dialogWrapper?.remove();
    this.dialogWrapper = null;
  }

  async fetchNotes() {
    this.fetchAbort = new AbortController();

    try {
      const response = await fetch(this.contentUrlValue, {
        headers: { Accept: "text/html" },
        signal: this.fetchAbort.signal,
      });

      if (!response.ok) return null;

      const html = await response.text();
      return html.trim().length > 0 ? html : null;
    } catch (error) {
      if (error.name !== "AbortError") {
        console.error("[Release Highlight] Failed to load notes:", error);
      }
      return null;
    }
  }

  removeInteractionListeners() {
    if (!this.handleFirstInteraction) return;
    window.removeEventListener("pointerdown", this.handleFirstInteraction, {
      capture: true,
    });
    window.removeEventListener("keydown", this.handleFirstInteraction, {
      capture: true,
    });
  }

  shownTag() {
    const flag = window.__releaseHighlightShownTag;
    return typeof flag === "object" && flag !== null ? flag.tag : flag;
  }

  ownsCurrentShownFlag() {
    const flag = window.__releaseHighlightShownTag;
    return (
      typeof flag === "object" &&
      flag !== null &&
      flag.tag === this.tagValue &&
      flag.token === this.shownFlagToken
    );
  }

  releaseShownFlag() {
    if (this.ownsCurrentShownFlag()) {
      window.__releaseHighlightShownTag = undefined;
    }
  }

  async markSeen() {
    if (this.markedSeen) return;
    this.markedSeen = true;

    const csrfToken = document.querySelector('meta[name="csrf-token"]');

    try {
      const response = await fetch(this.dismissUrlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          ...(csrfToken ? { "X-CSRF-Token": csrfToken.content } : {}),
        },
        body: JSON.stringify({ tag: this.tagValue }),
      });

      if (!response.ok) {
        console.error(
          "[Release Highlight] Failed to mark release seen:",
          response.status,
        );
      }
    } catch (error) {
      console.error(
        "[Release Highlight] Network error marking release seen:",
        error,
      );
    }
  }
}
