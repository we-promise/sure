import { Controller } from "@hotwired/stimulus";
import {
  captureDailyWebUsage,
  dailyWebUsageKey,
} from "utils/daily_web_usage";

export default class extends Controller {
  static values = { accountId: String, previewFeaturesEnabled: Boolean };

  connect() {
    this.resume();
  }

  disconnect() {
    this.pause();
  }

  pause() {
    this.active = false;
  }

  resume() {
    this.active = true;
    this.track();
  }

  track() {
    if (!this.visibleOpening()) return;
    const accountId = this.accountIdValue;
    const previewFeaturesEnabled = this.previewFeaturesEnabledValue;
    const capture = () => {
      // A queued lock or late SDK callback must not use a previous account's
      // cached page after logout, navigation, or a Turbo morph.
      if (!this.visibleOpening() || this.accountIdValue !== accountId) return;
      try {
        captureDailyWebUsage({
          posthog: window.posthog,
          accountId,
          previewFeaturesEnabled,
          storage: window.localStorage,
        });
      } catch {
        // Reading localStorage itself can throw when browser storage is blocked.
      }
    };

    try {
      if (navigator.locks?.request) {
        navigator.locks.request(dailyWebUsageKey(accountId), capture).catch(() => {});
      } else {
        capture();
      }
    } catch {
      // Browser permission failures must not interrupt a page visit.
    }
  }

  visibleOpening() {
    return (
      this.active &&
      this.element.isConnected &&
      this.accountIdValue &&
      !document.hidden &&
      !document.documentElement.hasAttribute("data-turbo-preview")
    );
  }
}
