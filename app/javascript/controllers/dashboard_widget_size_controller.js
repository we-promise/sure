import { Controller } from "@hotwired/stimulus";

// Per-widget layout picker (mounted on the <details> menu). Optimistically applies
// the choice for instant feedback, then persists it fire-and-forget — mirroring how
// collapse / reorder already save dashboard preferences:
//
//   - Height: sets the `--dash-widget-h` CSS var; the chart redraws via its own
//     ResizeObserver and dashboard-masonry re-packs from the height change.
//   - Width: toggles the `2xl:col-span-2` class; the CSS grid re-flows and a
//     synthetic resize nudges dashboard-masonry to re-pack.
export default class extends Controller {
  static values = { sectionKey: String };

  connect() {
    this._closeOnOutsideClick = this._closeOnOutsideClick.bind(this);
    document.addEventListener("click", this._closeOnOutsideClick);
  }

  disconnect() {
    document.removeEventListener("click", this._closeOnOutsideClick);
  }

  // Keep Enter/Space/arrow keydowns inside the menu from bubbling to the
  // section-level sortable-list handler, which would otherwise hijack them
  // to toggle keyboard reorder mode.
  stopKeydown(event) {
    event.stopPropagation();
  }

  selectHeight(event) {
    const { preset, height } = event.currentTarget.dataset;
    const section = this._section();
    if (section && height) {
      section.style.setProperty("--dash-widget-h", `${height}px`);
    }
    this._markSelected(event.currentTarget);
    this.element.open = false;
    this._save({ height: preset });
  }

  selectWidth(event) {
    const { colSpan } = event.currentTarget.dataset;
    const section = this._section();
    if (section) {
      section.classList.toggle("2xl:col-span-2", colSpan === "full");
    }
    this._markSelected(event.currentTarget);
    this.element.open = false;
    this._save({ col_span: colSpan });
    // Width change re-flows the grid; nudge dashboard-masonry to re-pack.
    window.dispatchEvent(new Event("resize"));
  }

  // Gridlines on/off for a time-series chart. Flipping the chart's Stimulus
  // `gridlines` value makes it redraw itself (including the label gutter), so
  // the change is instant. The menu stays open so the effect is visible.
  // The switch applies optimistically; if the save fails it is put back, so the
  // screen never claims a setting the server does not have.
  async toggleGridlines(event) {
    const checkbox = event.currentTarget;
    const enabled = checkbox.checked;
    const chart = this._section()?.querySelector(
      '[data-controller~="time-series-chart"]',
    );
    const apply = (value) =>
      chart?.setAttribute(
        "data-time-series-chart-gridlines-value",
        String(value),
      );

    // Rolling back to "the opposite of what I tried" breaks when toggles
    // overlap (on, then off, both failing would end up on). Roll back to the
    // last value the server confirmed instead, and only for the newest toggle.
    this._confirmedGridlines ??= checkbox.defaultChecked;
    this._gridlinesSequence = (this._gridlinesSequence ?? 0) + 1;
    const sequence = this._gridlinesSequence;

    apply(enabled);

    if (await this._save({ gridlines: enabled })) {
      this._confirmedGridlines = enabled;
    } else if (sequence === this._gridlinesSequence) {
      checkbox.checked = this._confirmedGridlines;
      apply(this._confirmedGridlines);
    }
  }

  _section() {
    return this.element.closest("[data-section-key]");
  }

  // Move the active state to the clicked segment within its segmented control,
  // mirroring DS::SegmentedControl's class + aria-pressed contract.
  _markSelected(button) {
    const group = button.closest(".segmented-control");
    if (!group) return;
    group.querySelectorAll(".segmented-control__segment").forEach((el) => {
      const on = el === button;
      el.classList.toggle("segmented-control__segment--active", on);
      el.setAttribute("aria-pressed", on ? "true" : "false");
    });
  }

  _closeOnOutsideClick(event) {
    if (this.element.open && !this.element.contains(event.target)) {
      this.element.open = false;
    }
  }

  // Resolves to true when the server accepted the change.
  async _save(payload) {
    const csrfToken = document.querySelector('meta[name="csrf-token"]');
    if (!csrfToken) {
      console.error("[Dashboard Widget Size] CSRF token not found.");
      return false;
    }

    try {
      const response = await fetch("/dashboard/preferences", {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken.content,
        },
        body: JSON.stringify({
          preferences: {
            dashboard_section_layout: { [this.sectionKeyValue]: payload },
          },
        }),
      });

      if (!response.ok) {
        console.error(
          "[Dashboard Widget Size] Failed to save layout:",
          response.status,
        );
      }

      return response.ok;
    } catch (error) {
      console.error(
        "[Dashboard Widget Size] Network error saving layout:",
        error,
      );
      return false;
    }
  }
}
