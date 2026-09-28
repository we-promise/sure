import { Controller } from "@hotwired/stimulus";

// Switches the dashboard cash-flow Sankey between flows by category and flows
// split by account. The view changes the chart's data, so the choice is saved
// to the user's dashboard preferences and the page reloads to rebuild it.
export default class extends Controller {
  async select(event) {
    const view = event.currentTarget.dataset.view;
    if (event.currentTarget.getAttribute("aria-pressed") === "true") return;

    const csrfToken = document.querySelector(
      'meta[name="csrf-token"]',
    )?.content;

    try {
      const response = await fetch("/dashboard/preferences", {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken,
        },
        body: JSON.stringify({ preferences: { cashflow_sankey_view: view } }),
      });

      if (!response.ok) {
        console.error(
          "[Cashflow Sankey] Failed to save view:",
          response.status,
        );
        return;
      }

      window.Turbo.visit(window.location.href, { action: "replace" });
    } catch (error) {
      console.error("[Cashflow Sankey] Network error saving view:", error);
    }
  }
}
