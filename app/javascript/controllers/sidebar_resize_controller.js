import { Controller } from "@hotwired/stimulus";
import {
  SIDEBAR_ABS_MAX,
  SIDEBAR_DEFAULTS,
  clampSidebarWidth,
} from "utils/sidebar_resize";
import {
  holdLayoutAnimating,
  markLayoutAnimating,
} from "utils/layout_animating";

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
  #handle = null;

  connect() {
    this.#applyStoredWidth("left");
    this.#applyStoredWidth("right");
  }

  // Ends a drag in progress as a pointerup would: Stimulus reuses this
  // controller if the element connects again, and a #drag left set would
  // ignore every later pointerdown (and keep the drag's cursor).
  disconnect() {
    this.#endResize();
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
    // One drag at a time: a second one would orphan the first's hold on
    // utils/layout_animating and leave the page marked.
    if (!sidebar || this.#drag) return;

    event.preventDefault();
    // The pointer that started the drag: only its events move or end it, so
    // another pointer (a second finger the browser cancels to scroll) can't
    // end a mouse or stylus drag still held.
    this.#drag = {
      side,
      sidebar,
      pointerId: event.pointerId,
      release: holdLayoutAnimating(),
    };

    // Suppress the open/close transition so the panel tracks the pointer 1:1.
    sidebar.style.transition = "none";
    document.body.style.userSelect = "none";
    document.body.style.cursor = "col-resize";

    this.#onMove = (moveEvent) => {
      if (this.#isDragPointer(moveEvent)) this.#resize(moveEvent);
    };
    this.#onUp = (upEvent) => {
      if (upEvent.type !== "blur" && !this.#isDragPointer(upEvent)) return;
      // Where the pointer was released is the drag's final width.
      if (upEvent.type === "pointerup") this.#resize(upEvent);
      this.#endResize();
    };
    window.addEventListener("pointermove", this.#onMove);
    window.addEventListener("pointerup", this.#onUp);
    // The browser can take a touch over (scrolling) and cancel the pointer.
    window.addEventListener("pointercancel", this.#onUp);
    // A button released outside the window, or the window losing focus
    // mid-drag, isn't guaranteed to reach the listeners above: capture the
    // pointer, and end the drag when that capture or the focus is lost.
    this.#handle = event.currentTarget;
    try {
      this.#handle?.setPointerCapture?.(event.pointerId);
    } catch (_e) {
      // Not an active pointer (a synthetic event): the window listeners remain.
    }
    this.#handle?.addEventListener("lostpointercapture", this.#onUp);
    window.addEventListener("blur", this.#onUp);
  }

  #isDragPointer(event) {
    const id = this.#drag?.pointerId;
    return id === undefined || event.pointerId === id;
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

    const { side, sidebar, release } = this.#drag;
    release();
    // Lay out the final width while transitions are still off, as a stored
    // width is applied: restored first, a width written by the last move but
    // not yet laid out would animate (max-width) after the drag ended.
    sidebar.getBoundingClientRect();
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

  // From the keyboard or a double-click: the sidebar animates to the new
  // width (its open/close transition), so the page is marked as for a toggle.
  #commitWidth(side, rawWidth) {
    const width = this.#clamp(side, rawWidth);
    const sidebar = this.#sidebar(side);
    if (sidebar && width !== this.#currentWidth(side))
      markLayoutAnimating(sidebar);
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
    const width = this.#clamp(side, requested);
    // #clamp reads the other sidebar's size, laying the page out at the
    // width it has now, so a different stored width would animate the
    // sidebar (its max-width) on every page load, laying out the activity
    // rows each frame. A restored width applies at once instead.
    const sidebar = this.#sidebar(side);
    if (sidebar) sidebar.style.transition = "none";
    this.#setWidth(side, width);
    if (sidebar) {
      sidebar.getBoundingClientRect();
      sidebar.style.transition = "";
    }
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
    if (this.#onUp) {
      window.removeEventListener("pointerup", this.#onUp);
      window.removeEventListener("pointercancel", this.#onUp);
      window.removeEventListener("blur", this.#onUp);
      this.#handle?.removeEventListener("lostpointercapture", this.#onUp);
    }
    this.#onMove = null;
    this.#onUp = null;
    this.#handle = null;
  }
}
