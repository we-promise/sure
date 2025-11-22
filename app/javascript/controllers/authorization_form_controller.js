import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  connect() {
    this.element.addEventListener("submit", async (event) => {
      event.preventDefault();
      const formData = new FormData(this.element);
      try {
        const response = await fetch(this.element.action, {
          method: "POST",
          headers: {
            "Accept": "application/json",
            "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content,
          },
          body: formData,
        });
        const data = await response.json();
        if (data.url) {
          window.location.assign(data.url);
        } else {
          alert("No authorization URL received.");
        }
      } catch (error) {
        console.error("Authorization error:", error);
        alert("Authorization error:", error);
      }
    });
  }
}
