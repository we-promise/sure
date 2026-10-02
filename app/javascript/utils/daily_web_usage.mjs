export const DAILY_WEB_USAGE_EVENT = "web_app_opened_daily";

export function dailyWebUsageKey(accountId) {
  // This account ID stays in the browser. It is not an event property.
  return `sure:daily-web-usage:${accountId}`;
}

export function captureDailyWebUsage({
  posthog,
  accountId,
  previewFeaturesEnabled,
  storage,
  now = new Date(),
}) {
  try {
    if (!accountId || typeof previewFeaturesEnabled !== "boolean") return false;
    if (posthog?.has_opted_out_capturing?.()) return false;

    // Use the browser's calendar day, not UTC or the long-lived Rails session.
    const day = [now.getFullYear(), now.getMonth() + 1, now.getDate()].join("-");
    const key = dailyWebUsageKey(accountId);
    let firstOpening;
    try {
      firstOpening = JSON.parse(storage.getItem(key));
    } catch (error) {
      if (!(error instanceof SyntaxError)) return false;
    }
    if (
      firstOpening?.day !== day ||
      typeof firstOpening.previewFeaturesEnabled !== "boolean" ||
      typeof firstOpening.captured !== "boolean"
    ) {
      firstOpening = { day, previewFeaturesEnabled, captured: false };
    }
    if (firstOpening.captured) return false;

    // Remember the first visible opening while the SDK loads, even if a later
    // navigation changes the preview preference before capture can succeed.
    storage.setItem(key, JSON.stringify(firstOpening));
    if (!posthog?.__loaded) return false;

    // Reserve before capture so ordinary reloads/tabs cannot inflate the count.
    // Storage failures skip capture; the controller also serializes tabs with
    // Web Locks where supported. A failed SDK attempt keeps the first state.
    storage.setItem(key, JSON.stringify({ ...firstOpening, captured: true }));
    try {
      if (
        posthog.capture(DAILY_WEB_USAGE_EVENT, {
          preview_features_enabled: firstOpening.previewFeaturesEnabled,
        })
      ) return true;
    } catch {
      // A blocked SDK must not affect the application or consume today's event.
    }
    storage.setItem(key, JSON.stringify(firstOpening));
  } catch {
    // Disabled storage and unavailable analytics leave the application usable.
  }
  return false;
}
