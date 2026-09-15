# Adding feature feedback surveys

Use `feedback_config(:feature_name)` from `FeedbackHelper` to select a survey.
Project routing belongs in this helper and `config/initializers/posthog.rb`;
question wording, response mapping, UI, and events belong to the feature.

## Configuration

`Rails.configuration.x.posthog` separates two things:

- `self_hosted_feedback_project` contains the shared public project token and
  ingestion host. All self-hosted feedback features use this destination.
- `feedback_surveys` maps feature symbols to their `managed` and `self_hosted`
  survey IDs. Only implemented features should be registered.

For example, the existing call is:

```erb
<% feedback = feedback_config(:sankey) %>
```

On managed app/demo deployments, the result contains `survey_id` for the current
installation. The feature uses the existing PostHog client, whose project is
selected by `POSTHOG_KEY` and `POSTHOG_HOST`. Each deployment sets the matching
feature survey variable; Sankey continues to use `POSTHOG_SANKEY_SURVEY_ID`.

For production self-hosted installations, the result contains `api_key`, `host`,
and `survey_id` for the shared `[app] self-hosted` project. The token is public
client configuration; operators need no account or key setup. It must never be a
PostHog personal or project secret key. An operator's own analytics configuration
must not change this destination.

Unknown features, blank survey IDs, or a missing ID for the selected destination
return `{}`. There is no fallback to another feature's survey or another project.
Self-hosted configuration also returns `{}` outside production or when
`POSTHOG_FEEDBACK_ENABLED=false`. This switch is specific to the shared
self-hosted feedback connection; managed deployments retain their existing rules.

## Adding the next feature

1. Create an API survey in each intended PostHog project. App and demo have
   distinct projects; self-hosted surveys belong in `[app] self-hosted`.
2. Add the feature to `feedback_surveys`, with a feature-specific environment
   variable for the managed survey and the shared project's public survey ID for
   self-hosting. Document the new environment variable in `.env.local.example`.
   Leave an unavailable destination unconfigured rather than borrowing an ID.
3. Call `feedback_config(:feature_name)` from the feature's view and pass values
   through escaped Stimulus data attributes. Keep the feature's access/preview
   gate at its existing web entry points; the helper does not grant access.
4. Implement the feature's survey contract and response mapping. Validate the
   active survey and question IDs, handle missing/blocked/opted-out analytics,
   and report success only after submission is accepted by the SDK.
5. Define the feature's event vocabulary and allowed properties. Preserve
   anonymous identity, existing capture opt-outs, and the self-hosted operator
   opt-out. Disable automatic capture, page tracking, session replay, and person
   profiles for the dedicated feedback client. Send free text only on explicit
   submission, and exclude financial records and incidental URL/device metadata.
6. Add offline tests for both destinations, distinct feature survey IDs, missing
   configuration, opt-outs, and the form's actual submission flow.

The helper only returns configuration; it does not initialize an SDK or submit
anything. The current `posthog.sankeyFeedback` client and its event allowlist are
Sankey-specific. Do not reuse its question assumptions or widen its event filter
implicitly when adding another feature. Make any shared browser-client extraction
alongside that feature with tests for both callers.

See [the Sankey implementation and active surveys](../hosting/sankey-preview-feedback.md)
for the first integration, and `test/helpers/feedback_helper_test.rb` for routing
coverage using a second test-only feature. No placeholder surveys are registered
in production.
