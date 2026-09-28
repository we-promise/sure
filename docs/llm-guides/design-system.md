# Design system

Consult [`app/assets/tailwind/sure-design-system.css`](../../app/assets/tailwind/sure-design-system.css)
and existing [`DS::*` components](../../app/components/DS/) before building UI.

- Use functional tokens: `text-primary`, `bg-container`, `border-primary`,
  `bg-warning/10`, `text-destructive`. Do not use raw palette classes or hex literals.
- Reach for `DS::Alert`, `DS::Button`, `DS::Disclosure`, `DS::Dialog`, `DS::Menu`
  and other existing primitives before making an alert, badge, button, disclosure,
  dialog or input shape.
- If a diff contains the same hand-built shape at least twice and no DS equivalent
  exists, propose a new DS primitive before introducing the second copy.
- Use the `icon` helper from [`ApplicationHelper`](../../app/helpers/application_helper.rb),
  never `lucide_icon` directly. Raw SVG belongs only inside DS primitives.
- Use scale tokens rather than arbitrary pixel values when a scale token fits.
- Do not add new styles to `sure-design-system.css` or
  [`application.css`](../../app/assets/tailwind/application.css) without explicit permission.
- Reviewers escalate DS reuse and repeated-shape violations to close/rewrite.
  Token, icon/SVG, localization and scale violations are request-changes.

For templates, Hotwire, Stimulus and localization guidance, see the
[UI guide](ui.md).

## Tables

Render data tables with [`DS::Table`](../../app/components/DS/table.rb), not
hand-written `<table>` markup. Declare each column once; the table renders the
header and every cell with the standard padding, header style and row rules.

```erb
<%= render DS::Table.new(rows: payments) do |table| %>
  <% table.with_column(t(".date")) { |payment| l(payment.date, format: :long) } %>
  <% table.with_column(t(".amount"), numeric: true, class: "privacy-sensitive") { |payment| format_money(payment.amount) } %>
<% end %>
```

- `numeric: true` for figures (right-aligned, tabular digits, no wrapping);
  `align: :right` for other right-hand columns such as actions.
- `inset: true` when the table sits inside a card. On the page background the
  table is a card of its own.
- `sticky_header: true` for long tables. Pass `label:` whenever the table can
  scroll, so keyboard users can reach it.
- A column block must output markup or return a String; call `to_s` on numbers.
