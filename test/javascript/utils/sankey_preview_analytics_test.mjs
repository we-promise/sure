import assert from "node:assert/strict";
import { test } from "node:test";
import { capturePreviewEvent, feedbackClient, initializeSelfHostedFeedback, selfHostedFeedbackOptions, sanitizeSelfHostedFeedback, sankeyFeedbackSurvey, sankeyFeedbackResponse } from "../../../app/javascript/utils/sankey_preview_analytics.mjs";

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


test("routes managed environments to their existing project and self-hosting only to the feedback project", () => {
  const shared = { __loaded: true };
  const posthog = { __loaded: true, sankeyFeedback: shared };
  assert.equal(feedbackClient(posthog, false), posthog);
  assert.equal(feedbackClient(posthog, true), shared);
  assert.equal(feedbackClient({ __loaded: true }, true), undefined);
  posthog.has_opted_out_capturing = () => true;
  assert.equal(feedbackClient(posthog, true), undefined);
  assert.equal(feedbackClient(posthog, false), undefined);
});

test("dedicated initialization is optional, idempotent and announces readiness after the named client exists", async () => {
  const calls = [];
  const sdk = { init(...args) { calls.push(args); args[1].loaded(); this.sankeyFeedback = {}; } };
  let readyClient;
  const ready = () => { readyClient = sdk.sankeyFeedback; };
  initializeSelfHostedFeedback(sdk, "", "https://us.i.posthog.com", ready);
  assert.equal(calls.length, 0);
  initializeSelfHostedFeedback(sdk, "public-feedback-token", "https://us.i.posthog.com", ready);
  initializeSelfHostedFeedback(sdk, "public-feedback-token", "https://us.i.posthog.com", ready);
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], "public-feedback-token");
  assert.equal(calls[0][2], "sankeyFeedback");
  assert.equal(readyClient, undefined);
  await Promise.resolve();
  assert.equal(readyClient, sdk.sankeyFeedback);
  assert.doesNotThrow(() => initializeSelfHostedFeedback({ init() { throw Error("blocked"); } }, "key", "host", ready));
  initializeSelfHostedFeedback({ has_opted_out_capturing: () => true, init() { assert.fail("opt-out must prevent initialization"); } }, "key", "host", ready);
});

test("self-hosted feedback disables automatic collection and strips incidental SDK metadata", () => {
  const options = selfHostedFeedbackOptions("https://us.i.posthog.com");
  for (const name of ["autocapture", "capture_pageview", "capture_pageleave", "capture_dead_clicks", "capture_exceptions", "capture_heatmaps", "capture_performance", "enable_recording_console_log"]) assert.equal(options[name], false);
  assert.equal(options.disable_session_recording, true);
  assert.equal(options.person_profiles, "never");
  assert.equal(options.persistence, "memory");
  const event = options.before_send({ event: "sankey_preview_displayed", properties: {
    token: "public-project-token", distinct_id: "anonymous", preview_version: "cash_flow_v1", surface: "inline", state: "content",
    $current_url: "https://private.example/", $referrer: "https://private.example/accounts", email: "private@example.test", $set: { name: "Private" }, $device_id: "device",
  } });
  assert.deepEqual(event.properties, { token: "public-project-token", distinct_id: "anonymous", preview_version: "cash_flow_v1", surface: "inline", state: "content", $geoip_disable: true, $process_person_profile: false });
  assert.equal(sanitizeSelfHostedFeedback({ event: "$pageview" }), null);
  assert.equal(sanitizeSelfHostedFeedback({ event: "$identify" }), null);
  const responseKey = "$survey_response_01a0a162-73a2-0000-9402-ffab5bc45b4a";
  assert.equal(sanitizeSelfHostedFeedback({ event: "survey sent", properties: { [responseKey]: "Labels overlap" } }).properties[responseKey], "Labels overlap");
  assert.equal(sanitizeSelfHostedFeedback({ event: "survey shown", properties: { [responseKey]: "Not submitted" } }).properties[responseKey], undefined);
});
