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
    try {
      // Show loading state if we have a link target (on method selector page)
      if (this.hasLinkTarget) {
        this.showLoading();
      }

      // Fetch accounts in background to populate cache
      const url = new URL(
        "/lunchflow_items/preload_accounts",
        window.location.origin
      );
      if (this.hasAccountableTypeValue) {
        url.searchParams.append("accountable_type", this.accountableTypeValue);
      }
      if (this.hasReturnToValue) {
        url.searchParams.append("return_to", this.returnToValue);
      }

      const csrfToken = document.querySelector('[name="csrf-token"]');
      const headers = {
        Accept: "application/json",
      };
      if (csrfToken) {
        headers["X-CSRF-Token"] = csrfToken.content;
      }

      const response = await fetch(url, { headers });

      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`);
      }

      const data = await response.json();

      if (data.success && data.has_accounts) {
        // Accounts loaded successfully, enable the link
        if (this.hasLinkTarget) {
          this.hideLoading();
        }
      } else if (data.error === "no_credentials") {
        // No credentials configured - keep link visible so user can see setup message
        if (this.hasLinkTarget) {
          this.hideLoading();
        }
      } else if (data.has_accounts === false) {
        // Credentials configured and API works, but no accounts available - hide the link
        if (this.hasLinkTarget) {
          this.linkTarget.style.display = "none";
        }
      } else if (data.has_accounts === null || data.error === "api_error" || data.error === "unexpected_error") {
        // API error (bad credentials, network issue, etc) - keep link visible, user will see error when clicked
        if (this.hasLinkTarget) {
          this.hideLoading();
        }
      } else {
        // Other error - keep link visible
        if (this.hasLinkTarget) {
          this.hideLoading();
        }
        console.error("Failed to preload Lunchflow accounts:", data.error);
      }
    } catch (error) {
      // On error, still enable the link so user can try
      if (this.hasLinkTarget) {
        this.hideLoading();
      }
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
