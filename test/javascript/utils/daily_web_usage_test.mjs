import assert from "node:assert/strict";
import { test } from "node:test";
import { captureDailyWebUsage, dailyWebUsageKey } from "../../../app/javascript/utils/daily_web_usage.mjs";

function fixture() {
  const items = new Map();
  const events = [];
  return {
    items,
    events,
    options: {
      accountId: "local-account-a",
      previewFeaturesEnabled: false,
      now: new Date(2026, 9, 2, 12),
      storage: {
        getItem: (key) => items.get(key) ?? null,
        setItem: (key, value) => items.set(key, value),
      },
      posthog: {
        __loaded: true,
        has_opted_out_capturing: () => false,
        capture(event, properties) {
          events.push({ event, properties });
          return {};
        },
      },
    },
  };
}

test("captures one Boolean-only event per local account and day", () => {
  const { options, events } = fixture();
  assert.equal(captureDailyWebUsage(options), true);
  assert.equal(captureDailyWebUsage({ ...options }), false);
  assert.equal(captureDailyWebUsage({ ...options, previewFeaturesEnabled: true }), false);
  assert.deepEqual(events, [{
    event: "web_app_opened_daily",
    properties: { preview_features_enabled: false },
  }]);
  assert.equal(captureDailyWebUsage({ ...options, now: new Date(2026, 9, 3), previewFeaturesEnabled: true }), true);
  assert.equal(events[1].properties.preview_features_enabled, true);
});

test("a different account is counted independently on the same browser", () => {
  const { options, events } = fixture();
  assert.equal(captureDailyWebUsage(options), true);
  assert.equal(captureDailyWebUsage({ ...options, accountId: "local-account-b", previewFeaturesEnabled: true }), true);
  assert.equal(captureDailyWebUsage(options), false);
  assert.deepEqual(events.map(({ properties }) => properties), [
    { preview_features_enabled: false }, { preview_features_enabled: true },
  ]);
});

test("local midnight, rather than UTC midnight, starts a new counting day", () => {
  const previousZone = process.env.TZ;
  process.env.TZ = "America/Los_Angeles";
  try {
    const { options, events } = fixture();
    const beforeMidnight = new Date("2026-10-02T06:59:59Z");
    const afterMidnight = new Date("2026-10-02T07:00:00Z");
    assert.equal(captureDailyWebUsage({ ...options, now: beforeMidnight }), true);
    assert.equal(captureDailyWebUsage({ ...options, now: afterMidnight }), true);
    assert.equal(events.length, 2);
  } finally {
    if (previousZone === undefined) delete process.env.TZ;
    else process.env.TZ = previousZone;
  }
});

test("late SDK readiness preserves the first opening's state across tracker instances", () => {
  const { options, events } = fixture();
  assert.equal(captureDailyWebUsage({ ...options, posthog: undefined }), false);
  assert.equal(captureDailyWebUsage({ ...options, previewFeaturesEnabled: true }), true);
  assert.deepEqual(events[0].properties, { preview_features_enabled: false });
});

test("declined or throwing capture can retry without replacing the first state", () => {
  for (const capture of [() => undefined, () => false, () => { throw Error("blocked"); }]) {
    const { options, events } = fixture();
    assert.equal(captureDailyWebUsage({ ...options, posthog: { __loaded: true, capture } }), false);
    assert.equal(captureDailyWebUsage({ ...options, previewFeaturesEnabled: true }), true);
    assert.deepEqual(events[0].properties, { preview_features_enabled: false });
  }
});

test("SDK opt-out does not capture or create a daily marker", () => {
  const { options, events, items } = fixture();
  options.posthog.has_opted_out_capturing = () => true;
  assert.equal(captureDailyWebUsage(options), false);
  assert.equal(events.length, 0);
  assert.equal(items.size, 0);
});

test("shared self-hosted feedback is never a fallback analytics destination", () => {
  const { options, events } = fixture();
  const posthog = { sankeyFeedback: options.posthog };
  assert.equal(captureDailyWebUsage({ ...options, posthog }), false);
  assert.equal(events.length, 0);
});

test("missing identity, invalid Boolean or unavailable storage cannot emit", () => {
  for (const changes of [
    { accountId: "" }, { previewFeaturesEnabled: "false" }, { storage: undefined },
    { storage: { getItem: () => { throw Error("blocked read"); } } },
    { storage: { getItem: () => null, setItem: () => { throw Error("blocked write"); } } },
  ]) {
    const { options, events } = fixture();
    assert.equal(captureDailyWebUsage({ ...options, ...changes }), false);
    assert.equal(events.length, 0);
  }
});

test("malformed browser markers do not break capture", () => {
  for (const value of ["not json", "null", '{"day":"2026-10-2","captured":"true"}']) {
    const { options, items, events } = fixture();
    items.set(dailyWebUsageKey(options.accountId), value);
    assert.equal(captureDailyWebUsage(options), true);
    assert.equal(events.length, 1);
  }
});
