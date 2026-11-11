import { Controller } from "@hotwired/stimulus";

// A group name cut short in a narrow sidebar slides once to show its end and
// back when its group is tapped or gets keyboard focus; on hover its title
// shows the full name. One pass, well under five seconds, then it rests.
// With reduced motion the layout shows the full name instead (the total
// moves below it), so nothing moves.
export default class extends Controller {
  static targets = ["text"];

  connect() {
    this.summary = this.element.closest("summary");
    this.summary?.addEventListener("focus", this.#onFocus);
    this.summary?.addEventListener("pointerup", this.#onPointerUp);
  }

  disconnect() {
    this.summary?.removeEventListener("focus", this.#onFocus);
    this.summary?.removeEventListener("pointerup", this.#onPointerUp);
    this.animation?.cancel();
  }

  #onFocus = () => {
    if (this.summary.matches(":focus-visible")) this.#play();
  };

  #onPointerUp = (event) => {
    if (event.pointerType === "touch") this.#play();
  };

  #play() {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    if (this.animation?.playState === "running") return;

    const distance = this.element.scrollWidth - this.element.clientWidth;
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
    this.element.style.textOverflow = "clip";
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
    const rest = () => {
      this.element.style.textOverflow = "";
      this.textTarget.style.display = "";
    };
    this.animation.addEventListener("finish", rest);
    this.animation.addEventListener("cancel", rest);
  }
}
