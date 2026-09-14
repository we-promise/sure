# Sankey preview feedback

The dashboard retains the original Sankey's server calculation, JavaScript
renderer, zoom, expansion and transaction links. A user who enables Settings →
Preferences → Preview features sees an independent API-backed chart immediately
below it. Both charts follow the existing period picker and section visibility.
The preview renderer is deliberately separate while users compare the results.

The API remains available to authenticated native clients regardless of the web
preview preference. The preference gates the extra web chart, not `cash_flow`.

## PostHog survey setup

Use the same PostHog project as the installation's existing `POSTHOG_KEY` and
`POSTHOG_HOST`. PostHog is initialized by the existing production-only snippet.
Enable Surveys in that project's settings, then create and launch an **API** survey:

- Name: `Cash flow Sankey preview feedback`
- Single choice question: `Does the new cash flow chart look right?`
  Choices: `Looks right`, `Something looks wrong` (keep these wire values).
- Optional open text question: `What did not show correctly, or what worked well?`
- No additional PostHog targeting; the app's per-user preview preference owns access.
- Leave the survey active with no end date. Users may send feedback about more
  than one period; responses are not suppressed after the first submission.

Set `POSTHOG_SANKEY_SURVEY_ID` to its survey UUID. This is public configuration,
not a personal API key. Never put a PostHog personal API key in the app.
The client fetches the configured survey with `getSurveys`, validates its shape,
and uses its question UUIDs, so reordering the two questions is safe. Renaming or
adding choices/questions requires updating the client contract at the same time.

The thumbs controls open Sure's accessible dialog. The form uses PostHog's
[custom survey integration](https://posthog.com/docs/surveys/implementing-custom-surveys)
and emits `survey shown`, `survey sent`, and `survey dismissed`. Responses use
`$survey_response_<question UUID>` and `$survey_id`, and appear in PostHog Surveys.
Submitting the form is the only action that sends the written response.

Missing configuration, an unavailable SDK, opted-out capture, an inactive survey,
or an incompatible survey shows an unavailable message rather than claiming a
response was submitted. The charts remain usable.

## Events and counting

`sankey_preview_displayed` is emitted when a loaded result enters the viewport in
a visible document. Its properties are `preview_version: cash_flow_v1`,
`surface: inline | expanded`, and `state: content | empty | error`.

Each page visit, date-range load, or retry can produce an inline impression.
Intersection/resize callbacks and scrolling back over the same rendered result
do not inflate the count. Each explicit expansion produces another impression
with `surface: expanded`. A hidden, collapsed, loading, or off-screen preview does
not count; late SDK initialization can capture an already visible result.

`sankey_preview_feedback_clicked` records `rating: positive | negative` and the
load state. All preview and survey events include `preview_version`. Custom
event properties contain no amounts, category/account names or IDs, date ranges,
or graph payloads. PostHog still adds its usual SDK metadata. Preview charts and
the feedback form are excluded from autocapture/session recording; users are
asked not to put private financial details in their voluntary response.

Filter `sankey_preview_displayed` to `surface=inline, state=content` for chart
exposure counts, compare those with feedback clicks, and use the survey results
for positive/negative responses and written reports.

![Feedback dialog with synthetic test data](../screenshots/cash-flow-sankey-feedback.png)
