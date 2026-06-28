import { Controller } from "@hotwired/stimulus";
import {
  SIDEBAR_ABS_MAX,
  SIDEBAR_DEFAULTS,
  clampSidebarWidth,
} from "utils/sidebar_resize";

// Drives the draggable dividers on the left (accounts) and right (assistant)
// sidebars. The chosen width is stored as a CSS variable on the root layout
// element (consumed via `max-width: var(--left-sidebar-width)`) and persisted
// per-device in localStorage. Width changes compose with the show/hide toggle
// owned by app_layout_controller — collapsing wins via `w-0`, reopening
// restores the last width.
//
// Connects to data-controller="sidebar-resize"
export default class extends Controller {
  static targets = ["leftSidebar", "rightSidebar"];

  static STORAGE_KEYS = {
    left: "sure.sidebarWidth.left",
    right: "sure.sidebarWidth.right",
  };
  // Keyboard nudge step (px) for the focusable divider handles.
  static KEY_STEP = 16;

  #drag = null;
  #onMove = null;
  #onUp = null;

  connect() {
    this.#applyStoredWidth("left");
    this.#applyStoredWidth("right");
  }

  disconnect() {
    this.#teardownListeners();
  }

  startLeft(event) {
    this.#startResize(event, "left");
  }

  startRight(event) {
    this.#startResize(event, "right");
  }

  // Arrow keys nudge the focused divider; Home resets to the default width.
  keyLeft(event) {
    this.#keyResize(event, "left");
  }

  keyRight(event) {
    this.#keyResize(event, "right");
  }

  // Double-clicking a divider restores its default width.
  resetLeft() {
    this.#commitWidth("left", SIDEBAR_DEFAULTS.left);
  }

  resetRight() {
    this.#commitWidth("right", SIDEBAR_DEFAULTS.right);
  }

  #startResize(event, side) {
    const sidebar = this.#sidebar(side);
    if (!sidebar) return;

    event.preventDefault();
    this.#drag = { side, sidebar };

    // Suppress the open/close transition so the panel tracks the pointer 1:1.
    sidebar.style.transition = "none";
    document.body.style.userSelect = "none";
    document.body.style.cursor = "col-resize";

    this.#onMove = (moveEvent) => this.#resize(moveEvent);
    this.#onUp = () => this.#endResize();
    window.addEventListener("pointermove", this.#onMove);
    window.addEventListener("pointerup", this.#onUp, { once: true });
  }

  #resize(event) {
    if (!this.#drag) return;

    const { side, sidebar } = this.#drag;
    const rect = sidebar.getBoundingClientRect();
    // Left handle sits on the sidebar's right edge; right handle on its left.
    const raw =
      side === "left" ? event.clientX - rect.left : rect.right - event.clientX;

    this.#setWidth(side, this.#clamp(side, raw));
  }

  #endResize() {
    if (!this.#drag) return;

    const { side, sidebar } = this.#drag;
    sidebar.style.transition = "";
    document.body.style.userSelect = "";
    document.body.style.cursor = "";
    this.#teardownListeners();

    this.#persist(side, this.#currentWidth(side));
    this.#drag = null;
  }

  #keyResize(event, side) {
    // A left sidebar grows as its right edge moves right; a right sidebar grows
    // as its left edge moves left. Mirror the arrow direction per side so the
    // key matches the visual edge movement.
    const dir = side === "left" ? 1 : -1;
    const step = this.constructor.KEY_STEP;
    let next;
    if (event.key === "ArrowRight") {
      next = this.#currentWidth(side) + dir * step;
    } else if (event.key === "ArrowLeft") {
      next = this.#currentWidth(side) - dir * step;
    } else if (event.key === "Home") {
      next = SIDEBAR_DEFAULTS[side];
    } else {
      return;
    }

    event.preventDefault();
    this.#commitWidth(side, next);
  }

  #commitWidth(side, rawWidth) {
    const width = this.#clamp(side, rawWidth);
    this.#setWidth(side, width);
    this.#persist(side, width);
  }

  #applyStoredWidth(side) {
    let stored = Number.NaN;
    try {
      stored = Number.parseInt(
        localStorage.getItem(this.constructor.STORAGE_KEYS[side]),
        10,
      );
    } catch (_e) {
      // Storage blocked (private mode / locked down) — fall back to default.
    }
    const requested = Number.isFinite(stored) ? stored : SIDEBAR_DEFAULTS[side];
    this.#setWidth(side, this.#clamp(side, requested));
  }

  #clamp(side, rawWidth) {
    const opposite = this.#sidebar(side === "left" ? "right" : "left");
    // Use the opposite sidebar's *rendered* width, not its stored CSS variable:
    // a collapsed sidebar renders at 0 (w-0), so its space is correctly freed
    // for this one instead of staying reserved at the stored value.
    const otherWidth = opposite
      ? Math.round(opposite.getBoundingClientRect().width)
      : 0;

    return clampSidebarWidth(rawWidth, {
      viewportWidth: window.innerWidth || 1280,
      otherWidth,
      absMax: SIDEBAR_ABS_MAX[side],
    });
  }

  #persist(side, width) {
    try {
      localStorage.setItem(this.constructor.STORAGE_KEYS[side], String(width));
    } catch (_e) {
      // Private browsing / storage disabled — width still applies for this session.
    }
  }

  #setWidth(side, width) {
    this.element.style.setProperty(`--${side}-sidebar-width`, `${width}px`);
  }

  #currentWidth(side) {
    const value = Number.parseInt(
      this.element.style.getPropertyValue(`--${side}-sidebar-width`),
      10,
    );
    return Number.isFinite(value) ? value : SIDEBAR_DEFAULTS[side];
  }

  #sidebar(side) {
    if (side === "left") {
      return this.hasLeftSidebarTarget ? this.leftSidebarTarget : null;
    }
    return this.hasRightSidebarTarget ? this.rightSidebarTarget : null;
  }

  #teardownListeners() {
    if (this.#onMove) window.removeEventListener("pointermove", this.#onMove);
    if (this.#onUp) window.removeEventListener("pointerup", this.#onUp);
    this.#onMove = null;
    this.#onUp = null;
  }
}
