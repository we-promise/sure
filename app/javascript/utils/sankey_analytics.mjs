export const SANKEY_PREVIEW_VERSION = "cash_flow_v1";

export function captureSankeyDisplay(posthog, properties = {}) {
  try {
    if (!posthog?.__loaded || posthog.has_opted_out_capturing?.()) return false;
    return Boolean(
      posthog.capture("sankey_preview_displayed", {
        preview_version: SANKEY_PREVIEW_VERSION,
        surface: properties.surface,
        state: properties.state,
      }),
    );
  } catch {
    // Analytics availability must not affect the financial view.
    return false;
  }
}

export function sankeyClient(posthog, selfHosted) {
  if (posthog?.has_opted_out_capturing?.()) return undefined;
  return selfHosted ? posthog?.sankeyFeedback : posthog;
}

export function selfHostedTrackingOptions(host) {
  return {
    api_host: host,
    defaults: "2025-11-30",
    person_profiles: "never",
    persistence: "memory",
    autocapture: false,
    capture_pageview: false,
    capture_pageleave: false,
    capture_dead_clicks: false,
    capture_exceptions: false,
    capture_heatmaps: false,
    capture_performance: false,
    disable_session_recording: true,
    enable_recording_console_log: false,
    disable_surveys: true,
    before_send: sanitizeSelfHostedTracking,
  };
}

// A separate project must not receive SDK page URLs, referrers, person data,
// or any other telemetry from a self-hosted installation.
export function sanitizeSelfHostedTracking(event) {
  if (!event || event.event !== "sankey_preview_displayed") return null;
  const allowed = new Set([
    "token", "distinct_id", "preview_version", "surface", "state",
  ]);
  event.properties = Object.fromEntries(
    Object.entries(event.properties || {}).filter(([key]) => allowed.has(key)),
  );
  delete event.$set;
  delete event.$set_once;
  event.properties.$geoip_disable = true;
  event.properties.$process_person_profile = false;
  return event;
}

export function initializeSelfHostedTracking(posthog, key, host, loaded) {
  try {
    if (!key || posthog?.sankeyFeedback || posthog?.has_opted_out_capturing?.()) return;
    posthog?.init?.(key, {
      ...selfHostedTrackingOptions(host),
      // The SDK assigns named instances after their loaded callback returns.
      loaded: () => queueMicrotask(loaded),
    }, "sankeyFeedback");
  } catch {
    // Blocked analytics must not prevent chart setup or navigation.
  }
}

