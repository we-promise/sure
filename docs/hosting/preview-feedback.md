# Preview surveys and event capture

Preview features let users try changes before general release. Surveys collect
what worked and what needs improvement; usage events show whether users saw or
interacted with the feature. Enable previews in Settings → Preferences → Preview
features. Each feature owns its access checks, feedback UI, questions, and events.

The cash-flow Sankey is the first implementation. It appears below the original
chart for comparison and offers thumbs up/down followed by an optional written
response. The shared configuration supports future feature surveys, but the
current browser client and event allowlist are still specific to Sankey.

## Deployment and survey routing

| Deployment | Feedback destination | Configuration |
| --- | --- | --- |
| Sure app | Its existing `[app] sure-app` PostHog project | Existing `POSTHOG_KEY` / `POSTHOG_HOST`, plus the feature's survey ID |
| Demo | Its existing `[app] sure-demo` PostHog project | Existing `POSTHOG_KEY` / `POSTHOG_HOST`, plus the feature's survey ID |
| Production self-hosted | Shared `[app] self-hosted` project | Bundled public project token and feature survey ID; no operator setup |

Managed deployments must use a survey belonging to their own project. Sankey's
survey variable is `POSTHOG_SANKEY_SURVEY_ID`. Self-hosted feedback stays separate
from any analytics project configured by the operator. Operators can disable the
shared connection with `POSTHOG_FEEDBACK_ENABLED=false`; this does not reroute
feedback to another project. Shared collection is disabled outside production by default.

### Local testing

To test without changing Rails to production mode, temporarily set
`POSTHOG_DEVELOPMENT_ENABLED=true` in `.env.local` and restart your development
process. Remove the override and restart when finished. This opt-in only applies
to development; automated test environments remain disabled.

With `SELF_HOSTED=true`, enable Preview features and click the Sankey thumbs-up/down
buttons to test the bundled API survey. `POSTHOG_FEEDBACK_ENABLED=false` still
opts out. Standard pop-up surveys require `POSTHOG_KEY` / `POSTHOG_HOST` for their
project; managed Sankey feedback also requires `POSTHOG_SANKEY_SURVEY_ID`.
The override uses the configured live projects, so submitted responses are real.

The public project token routes requests to PostHog; it is not a private API key
and grants no access to collected data or administration. Never distribute a
personal or project-secret API key. Rotating bundled configuration requires a
release and installation upgrades; older versions retain the old token. See the
[development guide](../llm-guides/feedback-surveys.md) for configuration and rotation.

## Survey behavior

Use a PostHog **API survey** with Sure's own accessible dialog. The application
controls when the survey is offered and validates the configured survey and its
question IDs. Answers use question UUIDs rather than positional indexes. Changing
question types or accepted choices requires a corresponding client update.

Sankey currently expects one single-choice question with the wire values
`Looks right` and `Something looks wrong`, plus one open-text question. Users can
submit feedback more than once. Future features define their own question
contracts instead of inheriting these choices.

PostHog's [custom survey integration](https://posthog.com/docs/surveys/implementing-custom-surveys)
uses `survey shown`, `survey sent`, and `survey dismissed`, with `$survey_id` and
`$survey_response_<question UUID>` properties. Written feedback is sent only on
explicit submission. Missing configuration, unavailable surveys, blocked SDKs,
and capture opt-outs must leave the feature usable without claiming a successful
submission. SDK acceptance is not confirmation of eventual server ingestion.

## Event capture

For each preview, document the event names, allowed properties, exact trigger,
and repeat-counting rules. Keep exposure separate from feedback and interaction.
Give each implementation a version so results from changed behavior can be
compared. Add events only with their capture code, allowlist, and offline tests;
registering a survey does not automatically instrument the feature.

These are the events **currently implemented for Sankey**. All include
`preview_version: cash_flow_v1`:

| Event | Trigger | Additional properties |
| --- | --- | --- |
| `sankey_preview_displayed` | A loaded result becomes visible, or the chart is explicitly expanded | `surface: inline / expanded`, `state: content / empty / error` |
| `sankey_preview_feedback_clicked` | Thumbs up/down, when a survey ID and capture-enabled SDK are available | `rating: positive / negative`, `state` |
| `new_sankey_match` / `new_sankey_mismatch` | Valid comparison after analytics is ready; once per graph load, including period changes | None |
| `survey shown` | The validated survey form is presented | `$survey_id` |
| `survey sent` | An explicit submission is accepted by the SDK | `$survey_id`, answers keyed by question UUID |
| `survey dismissed` | A presented survey closes without submission | `$survey_id` |

### Automatic graph comparison

The browser compares the original dashboard graph and the validated preview graph
before D3 mutates either input. It sorts nodes by stable identity and links by
source/target identity, comparing amounts at the legacy chart's two-decimal
precision and percentages at one decimal. Localized legacy IDs for synthetic
Uncategorized/Other Investments categories map to the preview's stable IDs.
Array order,
labels, colors, and API-only metadata do not affect the result. An empty legacy
zero-valued center is equivalent to an empty preview graph. Missing or invalid
inputs produce no event. Zoomed and expanded views do not create new comparisons.

Only `new_sankey_match` or `new_sankey_mismatch`, plus `preview_version`, is sent
to PostHog. No graph, amount, category, user ID, or date range is included in the
comparison payload. Existing managed SDK metadata and self-hosted privacy rules
still apply. Intentional deficit/netting changes can produce mismatches;
a match proves input equivalence, not visual correctness. The separate requests
can also observe different data if transactions change between loads.

Each successful graph load can emit one comparison event after the SDK accepts
it. Reloading the dashboard, changing the period, or retrying the data request
starts a new comparison. Scrolling, resizing, zooming, expanding, and repeated
SDK-ready notifications do not duplicate that load's event. Missing or opted-out
analytics do not mark it captured; a later SDK-ready notification can retry.

There is no daily or lifetime user limit. Legacy `sankey_comparison_result`
preferences are ignored, so an earlier mismatch does not suppress a later match.
No date ranges or graph data are persisted for deduplication or sent to PostHog.
These events count compared loads, not unique users. SDK acceptance does not
guarantee ingestion. Historical events are not rewritten by this change.

### Counting exposure and engagement

Count `sankey_preview_displayed` with `surface=inline` and `state=content` for
chart exposure. Count `surface=expanded` separately for expansion usage. Empty
and error impressions describe visible result states, not successful charts.

An inline result counts once per load and state. Scrolling away and back or
resizing does not add impressions. Page visits, date changes, and retries can
produce new impressions; each explicit expansion counts again. Hidden,
collapsed, off-screen, and loading previews do not count. Late SDK initialization
can capture an already-visible result.

Currently, `content` means validated graph data loaded into a visible container;
it does not confirm that SVG rendering finished. There are no dedicated load-time,
render-success, zoom, or transaction-navigation events yet. Future instrumentation
should distinguish those outcomes and record successful rendering before using
impressions as proof that a chart rendered.

Compare exposure and expansion counts with feedback clicks and submitted
responses to understand engagement. These measure captured activity, not all
usage: blocked or opted-out analytics are absent. The self-hosted client uses an
in-memory anonymous identity, so distinct IDs are not reliable counts of returning
people or installations across visits.

## Privacy and extending the implementation

Usage properties must exclude amounts, account/category names or IDs, date
ranges, server URLs, and graph payloads. Ask users to omit private financial
details from voluntary text. The feature and feedback form are excluded from
autocapture and session recording.

Managed deployments retain their existing SDK metadata. The dedicated self-hosted
client disables automatic tracking, pageviews, session recording, and person
profiles; it strips incidental URL, referrer, and device metadata. Opting out of
either client suppresses capture. GeoIP enrichment is disabled, although the
ingestion service necessarily receives the network connection's IP address.

Use `feedback_config(:feature_name)` and the per-feature survey registry for the
next preview. Follow [Adding feature feedback surveys](../llm-guides/feedback-surveys.md)
for implementation and tests. Reuse project routing, while giving the new feature
its own questions and explicit event contract. Extending the browser client must
preserve the same routing, privacy, and opt-out behavior for both features.
