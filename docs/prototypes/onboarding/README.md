# Onboarding clickable prototype

This is the unchanged October 23, 2026 onboarding concept, included for feedback
before any Rails implementation. It is a standalone HTML file with embedded
styles, font, logo, and JavaScript. It is not wired into the application.

## Try it

Download [`index.html`](index.html) and open the file in a modern browser. No
installation, Rails server, account, or API key is needed. GitHub's file view
shows the source rather than running the prototype.

For a localhost preview, from the repository root run:

```sh
python3 -m http.server 8000 --bind 127.0.0.1 --directory docs/prototypes/onboarding
```

Then open `http://127.0.0.1:8000/`.

## Review the flow

- Choose previous finance tools, search the list, and try the exclusive
  "Nothing yet" option. The suggested next step changes with the selection.
- Switch between No AI (the default), Built-in AI, and an external AI agent.
- Preview the built-in provider success and error states. The key field is a
  read-only placeholder; no provider is contacted.
- Copy the proposed external-agent instructions. Selecting this mode does not
  connect an agent or grant access.
- Expand the optional goals selector. Whether to keep it remains a design
  question.
- Continue to the connect/import preview, then return to preferences.

Nothing is connected, uploaded, or persisted. Do not enter real credentials or
financial data. The listed products and provider options illustrate the design;
they do not promise importer compatibility or supported integrations.

The original October/v0.7.6 labels are retained to preserve the reviewed
artifact. They are historical concept labels, not a release commitment.

Related future work: [control-plane onboarding](https://github.com/we-promise/sure/issues/4573)
and [onboarding playbooks](https://github.com/we-promise/sure/issues/4574).

## Scope

This directory is review material only. It adds no Rails routes, views, models,
migrations, provider integrations, authentication, analytics, or production
assets. Feedback on the draft PR comes before implementation.
