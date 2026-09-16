import assert from "node:assert/strict";
import { test } from "node:test";
import { captureSankeyDisplay, sankeyClient, initializeSelfHostedTracking, selfHostedTrackingOptions, sanitizeSelfHostedTracking } from "../../../app/javascript/utils/sankey_analytics.mjs";

test("missing, blocked, opted-out and throwing analytics do not break the view", () => {
  assert.equal(captureSankeyDisplay(undefined), false);
  assert.equal(captureSankeyDisplay({ __loaded: false }), false);
  assert.equal(captureSankeyDisplay({ __loaded: true, has_opted_out_capturing: () => true }), false);
  assert.equal(captureSankeyDisplay({ __loaded: true, capture() { throw new Error("Blocked"); } }), false);
});

test("display events contain only the version, surface and state", () => {
  const captures = [];
  const posthog = { __loaded: true, capture(event, properties) { captures.push({ event, properties }); return {}; } };
  assert.equal(captureSankeyDisplay(posthog, { surface: "inline", state: "content", amount: 123, category: "private" }), true);
  assert.deepEqual(captures, [{ event: "sankey_preview_displayed", properties: { preview_version: "cash_flow_v1", surface: "inline", state: "content" } }]);
});


test("routes managed environments to their existing project and self-hosting only to the feedback project", () => {
  const shared = { __loaded: true };
  const posthog = { __loaded: true, sankeyFeedback: shared };
  assert.equal(sankeyClient(posthog, false), posthog);
  assert.equal(sankeyClient(posthog, true), shared);
  assert.equal(sankeyClient({ __loaded: true }, true), undefined);
  posthog.has_opted_out_capturing = () => true;
  assert.equal(sankeyClient(posthog, true), undefined);
  assert.equal(sankeyClient(posthog, false), undefined);
});

test("dedicated initialization is optional, idempotent and announces readiness after the named client exists", async () => {
  const calls = [];
  const sdk = { init(...args) { calls.push(args); args[1].loaded(); this.sankeyFeedback = {}; } };
  let readyClient;
  const ready = () => { readyClient = sdk.sankeyFeedback; };
  initializeSelfHostedTracking(sdk, "", "https://us.i.posthog.com", ready);
  assert.equal(calls.length, 0);
  initializeSelfHostedTracking(sdk, "public-feedback-token", "https://us.i.posthog.com", ready);
  initializeSelfHostedTracking(sdk, "public-feedback-token", "https://us.i.posthog.com", ready);
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], "public-feedback-token");
  assert.equal(calls[0][2], "sankeyFeedback");
  assert.equal(readyClient, undefined);
  await Promise.resolve();
  assert.equal(readyClient, sdk.sankeyFeedback);
  assert.doesNotThrow(() => initializeSelfHostedTracking({ init() { throw Error("blocked"); } }, "key", "host", ready));
  initializeSelfHostedTracking({ has_opted_out_capturing: () => true, init() { assert.fail("opt-out must prevent initialization"); } }, "key", "host", ready);
});

test("self-hosted feedback disables automatic collection and strips incidental SDK metadata", () => {
  const options = selfHostedTrackingOptions("https://us.i.posthog.com");
  for (const name of ["autocapture", "capture_pageview", "capture_pageleave", "capture_dead_clicks", "capture_exceptions", "capture_heatmaps", "capture_performance", "enable_recording_console_log"]) assert.equal(options[name], false);
  assert.equal(options.disable_session_recording, true);
  assert.equal(options.person_profiles, "never");
  assert.equal(options.persistence, "memory");
  const event = options.before_send({ event: "sankey_preview_displayed", properties: {
    token: "public-project-token", distinct_id: "anonymous", preview_version: "cash_flow_v1", surface: "inline", state: "content",
    $current_url: "https://private.example/", $referrer: "https://private.example/accounts", email: "private@example.test", $set: { name: "Private" }, $device_id: "device",
  } });
  assert.deepEqual(event.properties, { token: "public-project-token", distinct_id: "anonymous", preview_version: "cash_flow_v1", surface: "inline", state: "content", $geoip_disable: true, $process_person_profile: false });
  assert.equal(sanitizeSelfHostedTracking({ event: "$pageview" }), null);
  assert.equal(sanitizeSelfHostedTracking({ event: "$identify" }), null);
  assert.equal(options.disable_surveys, true);
  for (const event of ["survey shown", "survey sent", "survey dismissed", "new_sankey_match", "new_sankey_mismatch", "sankey_preview_feedback_clicked"]) {
    assert.equal(sanitizeSelfHostedTracking({ event }), null);
  }
});
