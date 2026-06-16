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
  // section-level dashboard-sortable handler, which would otherwise hijack them
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

  async _save(payload) {
    const csrfToken = document.querySelector('meta[name="csrf-token"]');
    if (!csrfToken) {
      console.error("[Dashboard Widget Size] CSRF token not found.");
      return;
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
    } catch (error) {
      console.error(
        "[Dashboard Widget Size] Network error saving layout:",
        error,
      );
    }
  }
}
