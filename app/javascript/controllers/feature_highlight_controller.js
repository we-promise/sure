import { Controller } from "@hotwired/stimulus";
import { driver } from "driver.js";

// Anchored feature highlight (e.g. "Meet Bills" for v0.7.5).
//
// One driver.js popover per feature per account, spotlighting the feature's
// nav entry instead of floating centered. Dashboard only - the mount partial
// lives in the dashboard template.
//
// Sequencing with the "What's new" release popup: when a release highlight
// is mounted on the same page, this controller stays quiet until the
// release controller dispatches "release-highlight:settled" (the user
// dismissed the popup, or there was nothing to show), so the two popovers
// never compete for the overlay. The user is mid-interaction at that point,
// so the popover fires on a short delay instead of waiting for a fresh
// interaction. With no release highlight mounted, it fires on the first
// real pointer/keyboard interaction, same as the release popup.
//
// Nav items render twice (desktop rail + mobile bottom bar) with exactly
// one copy displayed at a time, so the anchor is the visible copy, picked
// via offsetParent. If no anchor is found, driver.js centers the popover.
export default class extends Controller {
  static values = {
    key: String,
    title: String,
    description: String,
    doneLabel: String,
    dismissUrl: String,
  };

  connect() {
    if (this.shownKey() === this.keyValue) return;

    this.handleFirstInteraction = this.handleFirstInteraction.bind(this);
    this.handleReleaseSettled = this.handleReleaseSettled.bind(this);

    if (this.releaseHighlightSettled()) {
      // The release popup already settled before this mount connected (e.g.
      // a Turbo-cached page restored after dismissal): follow it directly.
      this.handleReleaseSettled();
    } else if (this.releaseHighlightMounted()) {
      window.addEventListener(
        "release-highlight:settled",
        this.handleReleaseSettled,
        { once: true },
      );
      // Fallback: if the event is missed (controller connected late, cached
      // mount that never re-dispatches), poll the window-level flag.
      this.settledPoll = window.setInterval(() => {
        if (this.releaseHighlightSettled()) {
          window.clearInterval(this.settledPoll);
          this.settledPoll = undefined;
          this.handleReleaseSettled();
        }
      }, 250);
    } else {
      this.armInteractionListeners();
    }
  }

  disconnect() {
    this.removeInteractionListeners();
    window.removeEventListener(
      "release-highlight:settled",
      this.handleReleaseSettled,
    );
    window.clearInterval(this.settledPoll);
    window.clearTimeout(this.showTimeout);

    if (this.driverObj) {
      // Tearing down for navigation, not a user dismissal: do not mark seen.
      this.tearingDown = true;
      this.driverObj.destroy();
      this.driverObj = null;
    }

    if (!this.dismissed) this.releaseShownFlag();
  }

  handleFirstInteraction() {
    // Another mount already claimed this feature (Turbo reconnect, duplicate).
    if (this.shownKey() === this.keyValue) return;

    this.claimShownFlag();
    this.removeInteractionListeners();

    // Let the triggering interaction land before the popover takes over; if
    // it started a navigation, disconnect() cancels this before it shows.
    this.showTimeout = window.setTimeout(() => this.show(), 150);
  }

  handleReleaseSettled() {
    if (this.shownKey() === this.keyValue) return;

    this.claimShownFlag();

    // The user just dismissed the release popup, so they are already
    // interacting: follow it with a beat, not another wait for input.
    this.showTimeout = window.setTimeout(() => this.show(), 400);
  }

  show() {
    if (this.driverObj) return;

    const anchor = this.findAnchor();
    const desktop = window.matchMedia("(min-width: 1024px)").matches;

    this.driverObj = driver({
      showProgress: false,
      showButtons: ["close", "next"],
      doneBtnText: this.doneLabelValue,
      allowClose: true,
      overlayClickBehavior: "close",
      popoverClass: "release-highlight-popover feature-highlight-popover",
      steps: [
        {
          ...(anchor ? { element: anchor } : {}),
          popover: {
            title: this.titleValue,
            description: this.descriptionValue,
            side: desktop ? "right" : "top",
            align: desktop ? "start" : "center",
          },
        },
      ],
      // See the release controller: button clicks are the reliable
      // dismissal signal; onDestroyed is only a fallback.
      onDoneClick: () => this.dismissFromUser(),
      onCloseClick: () => this.dismissFromUser(),
      onDestroyed: () => {
        if (this.tearingDown) return;
        this.dismissFromUser(false);
      },
    });

    this.driverObj.drive();
  }

  // The nav item exists in both the desktop rail and the mobile bottom bar;
  // exactly one is displayed at a time (display:none on the other), and
  // offsetParent is null for hidden subtrees.
  findAnchor() {
    const candidates = document.querySelectorAll(
      `[data-feature-highlight="${this.keyValue}"]`,
    );

    for (const candidate of candidates) {
      if (candidate.offsetParent !== null) return candidate;
    }

    // No visible copy (e.g. the sidebar is collapsed): fall back to a
    // centered popover rather than spotlighting a hidden element.
    return null;
  }

  releaseHighlightMounted() {
    return Boolean(
      document.querySelector("[data-controller~='release-highlight']"),
    );
  }

  releaseHighlightSettled() {
    return window.__releaseHighlightSettled === true;
  }

  armInteractionListeners() {
    window.addEventListener("pointerdown", this.handleFirstInteraction, {
      capture: true,
      once: true,
    });
    window.addEventListener("keydown", this.handleFirstInteraction, {
      capture: true,
      once: true,
    });
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

  shownKey() {
    const flag = window.__featureHighlightShown;
    return typeof flag === "object" && flag !== null ? flag.key : flag;
  }

  claimShownFlag() {
    this.shownFlagToken = Symbol(this.keyValue);
    window.__featureHighlightShown = {
      key: this.keyValue,
      token: this.shownFlagToken,
    };
  }

  ownsCurrentShownFlag() {
    const flag = window.__featureHighlightShown;
    return (
      typeof flag === "object" &&
      flag !== null &&
      flag.key === this.keyValue &&
      flag.token === this.shownFlagToken
    );
  }

  releaseShownFlag() {
    if (this.ownsCurrentShownFlag()) {
      window.__featureHighlightShown = undefined;
    }
  }

  dismissFromUser(destroy = true) {
    if (this.dismissed) return;
    this.dismissed = true;

    this.markSeen();

    if (destroy) this.driverObj?.destroy();
  }

  async markSeen() {
    if (this.markedSeen) return;
    this.markedSeen = true;

    const csrfToken = document.querySelector('meta[name="csrf-token"]');

    try {
      const response = await fetch(this.dismissUrlValue, {
        method: "PATCH",
        headers: {
          ...(csrfToken ? { "X-CSRF-Token": csrfToken.content } : {}),
        },
      });

      if (!response.ok) {
        console.error(
          "[Feature Highlight] Failed to mark feature seen:",
          response.status,
        );
      }
    } catch (error) {
      console.error(
        "[Feature Highlight] Network error marking feature seen:",
        error,
      );
    }
  }
}
