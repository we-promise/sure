export const SANKEY_PREVIEW_VERSION = "cash_flow_v1";

export function capturePreviewEvent(posthog, event, properties = {}) {
  try {
    if (!posthog?.__loaded || posthog.has_opted_out_capturing?.()) return false;
    return Boolean(
      posthog.capture(event, {
        preview_version: SANKEY_PREVIEW_VERSION,
        ...properties,
      }),
    );
  } catch {
    // Analytics availability must not affect the financial view.
    return false;
  }
}

// The project owns the question UUIDs. Resolve them by type, never by order.
export function sankeyFeedbackSurvey(surveys, id) {
  if (!Array.isArray(surveys)) return null;
  const survey = surveys.find((candidate) => candidate?.id === id);
  if (
    !survey ||
    survey.type !== "api" ||
    !survey.start_date ||
    survey.end_date ||
    survey.archived
  )
    return null;
  if (!Array.isArray(survey.questions) || survey.questions.length !== 2)
    return null;
  const rating = survey.questions.find((q) => q?.type === "single_choice");
  const feedback = survey.questions.find((q) => q?.type === "open");
  if (
    !rating?.id ||
    !feedback?.id ||
    !feedback.question ||
    !Array.isArray(rating.choices) ||
    rating.choices.length !== 2 ||
    !rating.choices.includes("Looks right") ||
    !rating.choices.includes("Something looks wrong")
  )
    return null;
  return { id: survey.id, rating, feedback };
}

export function sankeyFeedbackResponse(survey, rating, feedback) {
  return {
    $survey_id: survey.id,
    [`$survey_response_${survey.rating.id}`]:
      rating === "positive" ? "Looks right" : "Something looks wrong",
    [`$survey_response_${survey.feedback.id}`]: feedback,
  };
}

export function feedbackClient(posthog, selfHosted) {
  if (posthog?.has_opted_out_capturing?.()) return undefined;
  return selfHosted ? posthog?.sankeyFeedback : posthog;
}

export function selfHostedFeedbackOptions(host) {
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
    disable_surveys: false,
    before_send: sanitizeSelfHostedFeedback,
  };
}

// A separate project must not receive SDK page URLs, referrers, person data,
// or any other telemetry from a self-hosted installation.
export function sanitizeSelfHostedFeedback(event) {
  if (!event || ![
    "sankey_preview_displayed",
    "sankey_preview_feedback_clicked",
    "new_sankey_match",
    "new_sankey_mismatch",
    "survey shown",
    "survey sent",
    "survey dismissed",
  ].includes(event.event)) return null;
  // The browser SDK carries its public ingestion token inside properties.
  const allowed = new Set([
    "token", "distinct_id", "preview_version", "surface", "state", "rating", "$survey_id",
  ]);
  event.properties = Object.fromEntries(
    Object.entries(event.properties || {}).filter(([key]) =>
      allowed.has(key) || (event.event === "survey sent" && /^\$survey_response_[\da-f-]+$/i.test(key)),
    ),
  );
  delete event.$set;
  delete event.$set_once;
  event.properties.$geoip_disable = true;
  event.properties.$process_person_profile = false;
  return event;
}

export function initializeSelfHostedFeedback(posthog, key, host, loaded) {
  try {
    if (!key || posthog?.sankeyFeedback || posthog?.has_opted_out_capturing?.()) return;
    posthog?.init?.(key, {
      ...selfHostedFeedbackOptions(host),
      // The SDK assigns named instances after their loaded callback returns.
      loaded: () => queueMicrotask(loaded),
    }, "sankeyFeedback");
  } catch {
    // Blocked analytics must not prevent chart setup or navigation.
  }
}

// Only the outcome leaves the browser, never the compared graphs.
// The controller deduplicates successful SDK captures for each graph load.
export function captureSankeyComparison(posthog, result) {
  if (!["match", "mismatch"].includes(result)) return false;
  return capturePreviewEvent(posthog, `new_sankey_${result}`);
}
