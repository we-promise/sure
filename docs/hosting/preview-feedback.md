# Sankey visualization tracking

The dashboard has one Sankey visualization, using the cash-flow graph shared with
mobile. It is available without preview opt-in. The original renderer, graph
comparison, feedback buttons and PostHog API survey integration have been removed.

## Events

Only `sankey_preview_displayed` remains. Its historical name and
`preview_version: cash_flow_v1` are retained for continuity in PostHog reports.
Properties are `surface` (`inline` or `expanded`) and `state` (`content`, `empty`
or `error`). Count inline content events for successful visible chart loads.
Each inline result is counted once per load after it becomes visible; scrolling,
resizing and SDK readiness notifications do not duplicate it. Expanding the chart
records an expanded display. Period changes and retries can record a new load.

No graph, amounts, categories, account identifiers or date ranges are sent.
Comparison events (`new_sankey_match` / `new_sankey_mismatch`) and all survey events
are retired.

## Destinations and opt-out

Managed installations use their existing configured PostHog project. Self-hosted
installations use the existing bundled public project and named `sankeyFeedback`
SDK instance; this historical name is retained for compatibility. Automatic
collection, surveys, session recording and person profiles are disabled on that
instance. Its allowlist accepts only the display event and strips incidental SDK
metadata such as URLs and referrers. Identity is anonymous and memory-only.

`POSTHOG_FEEDBACK_ENABLED=false` still disables bundled self-hosted tracking.
The existing SDK capture opt-out is also respected. Analytics failures never
prevent chart rendering or navigation.

Development is disabled by default. Set `POSTHOG_DEVELOPMENT_ENABLED=true` and
restart Rails for temporary local testing. This sends real display events.

## Rollout cleanup

Remove/archive the retired Sankey API survey in PostHog when this change ships,
including survey `01a0a162-73a2-0000-9402-ffab5bc45b4a` in the shared self-hosted
project and its managed app/demo counterparts. Remove `POSTHOG_SANKEY_SURVEY_ID`
from deployment configuration. This code change does not delete remote surveys.
