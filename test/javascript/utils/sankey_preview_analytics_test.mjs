import assert from "node:assert/strict";
import { test } from "node:test";
import { capturePreviewEvent, sankeyFeedbackSurvey, sankeyFeedbackResponse } from "../../../app/javascript/utils/sankey_preview_analytics.mjs";

const fixture = () => ({
  id: "test-survey", type: "api", start_date: "2026-09-14T00:00:00Z", end_date: null,
  questions: [
    { id: "feedback-id", type: "open", question: "What did not show correctly?", optional: true },
    { id: "rating-id", type: "single_choice", choices: ["Looks right", "Something looks wrong"] },
  ],
});

test("resolves real survey question IDs independently of order", () => {
  const survey = sankeyFeedbackSurvey([fixture()], "test-survey");
  assert.deepEqual(sankeyFeedbackResponse(survey, "negative", "Labels overlap"), {
    $survey_id: "test-survey",
    "$survey_response_rating-id": "Something looks wrong",
    "$survey_response_feedback-id": "Labels overlap",
  });
  assert.equal(sankeyFeedbackResponse(survey, "positive", "")["$survey_response_rating-id"], "Looks right");
});

test("rejects missing, inactive and incompatible surveys", () => {
  assert.equal(sankeyFeedbackSurvey([], "test-survey"), null);
  for (const changes of [{ start_date: null }, { end_date: "2026-09-14" }, { archived: true }, { type: "popover" }, { questions: [] }]) {
    assert.equal(sankeyFeedbackSurvey([{ ...fixture(), ...changes }], "test-survey"), null);
  }
});

test("missing, blocked, opted-out and throwing analytics do not break the view", () => {
  assert.equal(capturePreviewEvent(undefined, "sankey_preview_displayed"), false);
  assert.equal(capturePreviewEvent({ __loaded: false }, "sankey_preview_displayed"), false);
  assert.equal(capturePreviewEvent({ __loaded: true, has_opted_out_capturing: () => true }, "sankey_preview_displayed"), false);
  assert.equal(capturePreviewEvent({ __loaded: true, capture() { throw new Error("Blocked"); } }, "sankey_preview_displayed"), false);
});

test("display events contain only the version, surface and state", () => {
  const captures = [];
  const posthog = { __loaded: true, capture(event, properties) { captures.push({ event, properties }); return {}; } };
  assert.equal(capturePreviewEvent(posthog, "sankey_preview_displayed", { surface: "inline", state: "content" }), true);
  assert.deepEqual(captures, [{ event: "sankey_preview_displayed", properties: { preview_version: "cash_flow_v1", surface: "inline", state: "content" } }]);
});
