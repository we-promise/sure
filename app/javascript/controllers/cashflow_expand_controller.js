import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["inlineChart", "labelModeToggle"];

  open() {
    const dialog = this.element.querySelector("dialog");
    if (!dialog) return;

    if (typeof this.originalDraggable === "undefined") {
      this.originalDraggable = this.element.getAttribute("draggable");
    }
    this.element.setAttribute("draggable", "false");

    dialog.showModal();
  }

  restore() {
    if (this.originalDraggable === undefined) return;
    this.originalDraggable
      ? this.element.setAttribute("draggable", this.originalDraggable)
      : this.element.removeAttribute("draggable");
    this.originalDraggable = undefined;
  }

  // The header toggle drives the chart on the dashboard, not the one in the
  // expanded dialog.
  toggleLabelMode() {
    const chart = this.inlineChartTarget.querySelector(
      '[data-controller~="sankey-chart"]',
    );
    if (!chart) return;

    this.application
      .getControllerForElementAndIdentifier(chart, "sankey-chart")
      ?.toggleLabelMode();
  }

  syncLabelModeToggle({ detail: { available, showAll } }) {
    if (!this.hasLabelModeToggleTarget) return;

    const button = this.labelModeToggleTarget;
    const label = showAll
      ? button.dataset.collapseLabel
      : button.dataset.expandLabel;
    button.hidden = !available;
    button.title = label;
    button.setAttribute("aria-label", label);
    button.setAttribute("aria-expanded", String(showAll));

    const icon = (name) => button.querySelector(`[data-icon="${name}"]`);
    icon("expand").style.display = showAll ? "none" : "";
    icon("collapse").style.display = showAll ? "" : "none";
  }
}
