import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="lunchflow-preload"
export default class extends Controller {
  static targets = ["link", "spinner"];
  static values = {
    accountableType: String,
    returnTo: String,
  };

  connect() {
    this.preloadAccounts();
  }

  async preloadAccounts() {
    if (!this.hasLinkTarget) return;

    try {
      // Show loading state
      this.showLoading();

      // Fetch accounts in background to populate cache
      const url = new URL(
        "/lunchflow_items/preload_accounts",
        window.location.origin
      );
      url.searchParams.append("accountable_type", this.accountableTypeValue);
      if (this.returnToValue) {
        url.searchParams.append("return_to", this.returnToValue);
      }

      const response = await fetch(url, {
        headers: {
          Accept: "application/json",
          "X-CSRF-Token": document.querySelector('[name="csrf-token"]').content,
        },
      });

      const data = await response.json();

      if (data.success && data.has_accounts) {
        // Accounts loaded successfully, enable the link
        this.hideLoading();
      } else if (!data.has_accounts) {
        // No accounts available, hide the link entirely
        this.linkTarget.style.display = "none";
      } else {
        // Error occurred
        this.hideLoading();
        console.error("Failed to preload Lunchflow accounts:", data.error);
      }
    } catch (error) {
      // On error, still enable the link so user can try
      this.hideLoading();
      console.error("Error preloading Lunchflow accounts:", error);
    }
  }

  showLoading() {
    this.linkTarget.classList.add("pointer-events-none", "opacity-50");
    if (this.hasSpinnerTarget) {
      this.spinnerTarget.classList.remove("hidden");
    }
  }

  hideLoading() {
    this.linkTarget.classList.remove("pointer-events-none", "opacity-50");
    if (this.hasSpinnerTarget) {
      this.spinnerTarget.classList.add("hidden");
    }
  }
}
