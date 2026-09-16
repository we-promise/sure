# Feature tracking and surveys

The Sankey survey has been retired. Its visualization-only tracking is documented
in [Sankey visualization tracking](../hosting/preview-feedback.md).

`FeedbackHelper#sankey_tracking_config` returns the bundled self-hosted destination
only when the environment allows PostHog and the operator has not opted out.
Managed installations use their existing SDK. `utils/sankey_analytics` preserves
capture opt-outs and strips self-hosted telemetry to a strict display-event
allowlist. Do not add survey or comparison events to this visualization.

For future surveys, use a feature-specific implementation with explicit project
routing and privacy tests; there is no active generic survey registry. Reuse DS
primitives and keep user-entered feedback and financial data out of automatic
capture. Development PostHog remains default-off, with the explicit
`POSTHOG_DEVELOPMENT_ENABLED` testing override.
