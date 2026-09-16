import { Controller } from "@hotwired/stimulus";
import {
  captureSankeyDisplay,
  initializeSelfHostedTracking,
  sankeyClient,
} from "utils/sankey_analytics";

export default class extends Controller {
  static targets = ["display", "expandButton", "expandedDialog"];
  static values = {
    selfHosted: Boolean,
    feedbackKey: String,
    feedbackHost: String,
  };

  connect() {
    if (this.selfHostedValue) {
      initializeSelfHostedTracking(
        window.posthog,
        this.feedbackKeyValue,
        this.feedbackHostValue,
        () => document.dispatchEvent(new Event("posthog:ready")),
      );
    }
    this.displays = new Set();
    this.state = "loading";
    this.active = true;
    this.observer = new IntersectionObserver(([entry]) => {
      this.visible = entry.isIntersecting;
      this.trackDisplay();
    });
    this.observer.observe(this.displayTarget);
  }

  get posthog() {
    if (this.selfHostedValue && !this.feedbackKeyValue) return undefined;
    return sankeyClient(window.posthog, this.selfHostedValue);
  }

  disconnect() {
    this.clear();
    this.observer?.disconnect();
  }

  clear() {
    this.active = false;
    this.expandedDialogTarget.close();
    this.restoreDrag();
  }

  update({ detail }) {
    if (detail.state === "loading") {
      this.displays.clear();
    }
    this.state = detail.state;
    this.expandButtonTarget.disabled = !detail.ready;
    this.trackDisplay();
  }

  trackDisplay() {
    if (
      !this.active ||
      document.hidden ||
      !this.visible ||
      this.state === "loading" ||
      !this.displayTarget.getClientRects().length
    )
      return;
    // Count each rendered result once. Scrolling and resize callbacks aren't
    // additional displays; a date-range navigation creates a new controller.
    const key = `inline:${this.state}`;
    if (this.displays.has(key)) return;
    if (
      captureSankeyDisplay(this.posthog, {
        surface: "inline",
        state: this.state,
      })
    ) {
      this.displays.add(key);
    }
  }

  expand() {
    if (this.state !== "content" || this.expandedDialogTarget.open) return;
    this.section = this.element.closest(
      "[data-dashboard-sortable-target='section']",
    );
    this.originalDraggable = this.section?.getAttribute("draggable");
    this.section?.setAttribute("draggable", "false");
    this.expandedDialogTarget.showModal();
    captureSankeyDisplay(this.posthog, {
      surface: "expanded",
      state: this.state,
    });
  }

  restoreDrag() {
    if (!this.section) return;
    if (this.originalDraggable === null)
      this.section.removeAttribute("draggable");
    else this.section.setAttribute("draggable", this.originalDraggable);
    this.section = null;
  }

  stopKeydown(event) {
    // The enclosing dashboard section also handles Enter/Space for reordering.
    event.stopPropagation();
  }
}
