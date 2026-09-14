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
