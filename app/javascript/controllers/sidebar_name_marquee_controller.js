import { Controller } from "@hotwired/stimulus";

// A group name cut short in a narrow sidebar slides once to show its end and
// back when its group is tapped (a touch or a pen) or gets keyboard focus;
// on hover its title shows the full name. One pass, well under five seconds,
// then it rests. With reduced motion the layout shows the full name instead
// (the total moves below it), so nothing moves; a tap where the main pointer
// is fine (a touchscreen laptop) has no such layout, so the tap shows it.
// Sits on the group's <summary>, which declares the focus and pointerup
// actions.
export default class extends Controller {
  static targets = ["name", "text"];

  connect() {
    // A page Turbo cached mid-slide (or mid-reveal) keeps those styles and
    // marks; start at rest.
    this.#rest();
    this.element.removeAttribute("data-name-revealed");
  }

  disconnect() {
    this.animation?.cancel();
  }

  focus() {
    if (this.element.matches(":focus-visible")) this.#play();
  }

  // A mouse has hover, so the title shows the full name; any other pointer
  // (a finger, a pen that doesn't hover) gets the slide or the full name.
  tap(event) {
    if (event.pointerType === "mouse") return;
    if (this.#reducedMotion()) {
      if (this.#isCut()) this.element.setAttribute("data-name-revealed", "");
    } else {
      this.#play();
    }
  }

  #reducedMotion() {
    return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  }

  #isCut() {
    return this.nameTarget.scrollWidth - this.nameTarget.clientWidth > 1;
  }

  #play() {
    if (this.#reducedMotion()) return;
    if (this.animation?.playState === "running") return;

    const distance = this.nameTarget.scrollWidth - this.nameTarget.clientWidth;
    if (distance <= 1) return;

    // About 40px a second, within 0.6-1.6s each way, with a short pause
    // before setting off and a longer one at the end of the name.
    const travel = Math.min(Math.max(distance * 25, 600), 1600);
    const startPause = 400;
    const endPause = 1000;
    const duration = startPause + travel + endPause + travel;
    const at = (ms) => ms / duration;
    const shown = `translateX(-${distance}px)`;

    // At rest the name is inline, so the ellipsis shows where it is cut; it
    // only becomes a box (which can move, and which no ellipsis can cut)
    // while it slides, without an ellipsis riding over it.
    this.nameTarget.style.textOverflow = "clip";
    this.textTarget.style.display = "inline-block";
    this.animation = this.textTarget.animate(
      [
        { transform: "translateX(0)", offset: 0 },
        { transform: "translateX(0)", offset: at(startPause) },
        { transform: shown, offset: at(startPause + travel) },
        { transform: shown, offset: at(startPause + travel + endPause) },
        { transform: "translateX(0)", offset: 1 },
      ],
      { duration, easing: "ease-in-out" },
    );
    this.animation.addEventListener("finish", this.#rest);
    this.animation.addEventListener("cancel", this.#rest);
  }

  #rest = () => {
    this.nameTarget.style.textOverflow = "";
    this.textTarget.style.display = "";
  };
}
