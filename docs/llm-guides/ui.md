# Views, components and interaction

Design tokens, `DS::*` reuse and reviewer severity live in the
[design system guide](design-system.md), which is also the always-on Cursor
design adapter. This guide covers templates, Hotwire, Stimulus and localization.

## Hotwire and templates

Prefer semantic native HTML, including `<dialog>` and `<details><summary>`, using
existing DS wrappers where available. Use Turbo Frames for page sections. Turbo
Streams should enhance functionality, not be its sole dependency.

Keep state in URL query parameters before reaching for local storage or sessions;
use the database when persistent state is necessary. Format money, numbers and
dates server-side and pass display values to Stimulus. Client-side behavior is
appropriate for interactions such as bulk selection where server round trips would
hurt usability.

Use an existing component first, then an existing partial. Create a ViewComponent
for reusable or complex styling/logic, variants/sizes, interaction, slots or a
configurable API, and accessibility/ARIA behavior. Use partials for mostly static,
simple or context-specific template content. Keep domain logic out of ERB; compute
presentation logic in helpers or component Ruby files.

Follow the names of nearby components, including the `DS::*` namespace; do not
impose the obsolete `ButtonComponent`/`DialogComponent` examples on this design
system. Partials use an underscore prefix; shared partials live in
`app/views/shared/`, context-specific partials under their controller's views.

## Stimulus

- Declare actions in HTML (`data-action="click->toggle#toggle"`) rather than
  imperatively registering event listeners in controller initialization.
- Keep controllers focused on one responsibility or tightly related responsibilities;
  domain logic belongs on the server.
- Aim for fewer than seven targets. Use private helpers and a clear public API,
  with Stimulus callbacks, actions, targets, values and classes.
- Controllers in `app/components/` belong only to their component templates;
  global controllers in `app/javascript/controllers/` may be shared across views.
- Pass data through `data-*-value` attributes rather than inline JavaScript. Use
  Stimulus targets rather than manual `getElementById` lookups.

## Localization

Use `t()` for all user-facing strings and update the corresponding locale files
under `config/locales/`. Follow the feature's existing locale organization; there
is no requirement to put every new key in a single `en.yml`.

Use descriptive, hierarchical keys such as `accounts.index.title` and
`components.transaction_details.show_details`. Group related keys together; use
interpolation (`t("users.greeting", name: user.name)`) and Rails pluralization
(`t("transactions.count", count: count)`) for dynamic text. Keep examples localized
too. Configure missing translations to raise during development; do not assume that this option is currently enabled in the
checked-in environment configuration.
