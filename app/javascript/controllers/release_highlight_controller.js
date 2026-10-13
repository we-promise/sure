import { Controller } from "@hotwired/stimulus";
import { driver } from "driver.js";

// "What's new" release highlight.
//
// Shows the deployed release's notes once per account:
//   1. waits for the first real pointer/keyboard interaction after page load
//      (so the popup never interrupts the initial render, and the PWA only
//      pops it once the user is actually engaging),
//   2. fetches the release notes for the pending tag (no notes = no popup),
//   3. opens one centered driver.js popover with the notes,
//   4. marks the release tag as seen server-side when the user dismisses it
//      (Done button, close icon, overlay click, or Escape).
//
// Navigating away without dismissing is not "seen": the popover is torn down
// quietly and the next page offers it again. A window-level flag keyed to the
// tag prevents double-shows across Turbo reconnects, cached page restores,
// and duplicate mounts.
export default class extends Controller {
  static values = {
    contentUrl: String,
    dismissUrl: String,
    tag: String,
    title: String,
    doneLabel: String,
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
    this.fetchAbort?.abort();

    if (this.driverObj) {
      // Tearing down for navigation, not a user dismissal: do not mark seen.
      this.tearingDown = true;
      this.driverObj.destroy();
      this.driverObj = null;
    }

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

    // Let the triggering interaction land before the popover takes over; if
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

    if (this.driverObj) return;

    this.driverObj = driver({
      showProgress: false,
      showButtons: ["close", "next"],
      doneBtnText: this.doneLabelValue,
      allowClose: true,
      overlayClickBehavior: "close",
      popoverClass: "release-highlight-popover",
      steps: [
        {
          popover: {
            title: this.titleValue,
            description: notesHtml,
          },
        },
      ],
      onDestroyed: () => {
        this.dismissed = !this.tearingDown;

        if (this.dismissed) {
          this.markSeen();
        }
      },
    });

    this.driverObj.drive();
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
