import { Controller } from "@hotwired/stimulus";

// Saves whether a section on a page built on the Reports section framework is
// collapsed. The section's <details> opens and closes itself; this saves the
// state its `toggle` event reports. It keeps the Reports name because renaming
// it would touch every Reports data attribute for no behaviour change.
export default class extends Controller {
  static targets = ["details"];
  // `url` and `preferenceKey` default to the Reports literals, so the Reports
  // page, which passes neither, posts to its own endpoint under its own key.
  // Another page passes both.
  static values = {
    sectionKey: String,
    collapsed: Boolean,
    url: { type: String, default: "/reports/update_preferences" },
    preferenceKey: { type: String, default: "reports" },
  };

  // `toggle` also fires for the open state the page was rendered with, so
  // only a change from the saved state is sent.
  save() {
    const collapsed = !this.detailsTarget.open;
    if (collapsed === this.collapsedValue) return;

    this.collapsedValue = collapsed;
    this.savePreference(collapsed);
  }

  savePreference(collapsed) {
    return this.patchPreferences({
      [`${this.preferenceKeyValue}_collapsed_sections`]: {
        [this.sectionKeyValue]: collapsed,
      },
    });
  }

  // A control inside a section that saves one preference value (given as
  // Stimulus action params) and reloads the page to show its effect.
  // Saves run one after another, so quick clicks reach the server in click
  // order and the last choice is the one stored; only the last save reloads.
  async savePreferenceValue({ params: { key, value } }) {
    const save = (this.pendingSave ?? Promise.resolve()).then(() =>
      this.patchPreferences({ [key]: value }),
    );
    this.pendingSave = save;

    if ((await save) && this.pendingSave === save) {
      window.Turbo.visit(window.location.href, { action: "replace" });
    }
  }

  async patchPreferences(preferences) {
    // Safely obtain CSRF token
    const csrfToken = document.querySelector('meta[name="csrf-token"]');
    if (!csrfToken) {
      console.error(
        "[Reports Section] CSRF token not found. Cannot save preferences.",
      );
      return false;
    }

    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken.content,
        },
        body: JSON.stringify({ preferences }),
      });

      if (!response.ok) {
        const errorData = await response.json().catch(() => ({}));
        console.error(
          "[Reports Section] Failed to save preferences:",
          response.status,
          errorData,
        );
      }
      return response.ok;
    } catch (error) {
      console.error(
        "[Reports Section] Network error saving preferences:",
        error,
      );
      return false;
    }
  }
}
