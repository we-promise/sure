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
- `sticky_header: true` for long tables.
- Pass `label:` whenever the table can scroll, including sideways on a narrow
  screen, so keyboard users can reach it.
- A column block must output markup or return a String; call `to_s` on numbers.

## Form actions

A form with one action ends in [`f.submit`](../../app/helpers/styled_form_builder.rb),
which renders a full-width primary `DS::Button` on a `styled_form_with` form. A
form with Cancel and a primary action ends in a right-aligned pair of
natural-width buttons at the default size: Cancel, then the primary action. The
variant carries the hierarchy, not the width.

```erb
<div class="flex justify-end gap-2">
  <%= render DS::Button.new(text: t(".cancel"), variant: :secondary, data: { action: "DS--dialog#close" }) %>
  <%= render DS::Button.new(text: t(".save"), type: :submit) %>
</div>
```

- Cancel takes `variant: :secondary` or `:ghost`. A Cancel that leaves the
  page is a `DS::Link` with the same variant.
- A destructive action takes `variant: :destructive` in the primary's place.
  `f.submit` is always primary, so a destructive single action is a
  `DS::Button` with `full_width: true` and `type: :submit`.
- Don't put `f.submit` in a pair: it is always full width and ignores
  `class:`. Render the primary with `type: :submit`, as above.
- Keep the default size. `size: :sm` text buttons are 28px tall, and the 44px
  coarse-pointer target only applies to icon-only buttons.
- When a [`DS::Dialog`](../../app/components/DS/dialog.rb)'s buttons don't
  submit a form, `dialog.with_action` renders this row; `cancel_action: true`
  makes a button close the dialog.
- Examples: [`budget_categories/_move_dialog`](../../app/views/budget_categories/_move_dialog.html.erb),
  [`goals/consume`](../../app/views/goals/consume.html.erb), the currencies
  dialog in [`settings/preferences/show`](../../app/views/settings/preferences/show.html.erb),
  the [bulk edit drawer](../../app/views/transactions/bulk_updates/new.html.erb)
  and the [filter popover](../../app/views/transactions/searches/_menu.html.erb).
- Amount inputs stay left-aligned, as `money_field` renders them. Right
  alignment with tabular digits is for displayed figures (`numeric: true`
  above) and for inputs inside a column of them, such as the budget grid.
