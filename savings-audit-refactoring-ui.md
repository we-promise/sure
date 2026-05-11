# Savings Goals — Refactoring UI Audit

Branch `feat/savings-goals` (we-promise/sure). Read-only audit using
Wathan & Schoger's *Refactoring UI*. Each finding cites a file:line,
severity (P0 ship-blocker, P1 fix-before-merge, P2 nice-to-have), the
RUI rule it breaks, and a minimal fix. Grouped by surface; Top-10
"ship now" at the bottom.

## Coverage caveat

Shots in `audit-shots/`. Clean captures: index (light/dark/mobile),
behind/on-track/no-target-date/reached/paused show, new-goal modal step
1, mobile show. Demo data regenerated mid-session and invalidated some
goal IDs, so edit-modal, add-contribution modal, contribution
delete-confirm, archived show, no-accounts empty state, and some mobile
modal states were read from source rather than from screenshots. All
findings are still grounded in real code paths.

---

## 1. Index — populated (light/dark/mobile)

`app/views/savings_goals/index.html.erb:11-68` — **P1** — KPI strip
gives three metrics identical visual weight. *Hierarchy — actions/stats
live in a pyramid.* All three cards use `text-3xl font-medium` on
`bg-container`; nothing answers the user's actual landing question ("am I
winning?"). Elevate "Goals on track" to a primary card with a larger
numeral + a ring/bar; demote velocity + needs to compact secondary
cards (`text-xl`, tighter padding).

`app/views/savings_goals/index.html.erb:13,36,49` — **P2** — Three card
panels read as one grey block in dark mode. *Depth — light-from-above.*
`bg-container` differs from `bg-app` by only ~4% L\* in dark. Add a faint
top-edge highlight (`ring-1 ring-inset ring-white/5`) so cards read as
raised, not tinted.

`app/views/savings_goals/index.html.erb:14,37,50` — **P2** — Three
adjacent eyebrows `text-[11px] uppercase tracking-wide text-secondary`
create striped chrome. *Typography — all-caps as decoration.* Commit to
one all-caps style (KPI eyebrows OR section headings, not both).

`app/views/savings_goals/index.html.erb:92-119` — **P1** — Search input
and chip group compete. *Forms — most-common action wins the row.*
Search uses `border border-secondary bg-container`; chips use
`bg-surface-inset` segmented. Drop the search border + `bg-surface-inset`,
cap to `md:max-w-xs`. At 1440 search currently stretches 600+px and
swallows the chip group's importance.

`app/views/savings_goals/index.html.erb:107` — **P1** — Chip filter
values duplicate status-pill semantics but in a different visual
language. *Color — single palette across the app.* Add a 1.5×1.5
colored dot prefix to each chip (same green/yellow/grey as the pill) so
filter and chip share visual identity.

`app/views/savings_goals/index.html.erb:123-127` — **P2** — "ONGOING ·
5" section heading shares chrome with KPI eyebrows. *Hierarchy — don't
repeat your hierarchy gestures.* Use `text-sm font-medium text-secondary`
for section headings; reserve all-caps eyebrows for KPI cards.

`app/components/savings/goal_card_component.html.erb:8-41` — **P1** —
Card has three competing focal points: avatar + name + pill, big
balance/target, and a ring with overlaid percent. *Cards — one job per
card.* Percent inside the ring repeats `current/target` underneath.
Drop one; let geometry tell the story OR let the numbers.

`app/components/savings/goal_card_component.html.erb:33-35` — **P2** —
`stroke-linecap="round"` is on the progress arc only. *Finishing
touches — consistency.* Apply to both circles for future-proofing
partial-track variants.

`app/components/savings/goal_card_component.html.erb:46` — **P2** —
`/ $50,000.00` is `text-xs text-subdued`. *Typography — hierarchy via
weight not just color.* In dark mode at 12px the slash + number sit
near noise. Bump to `text-secondary`; the slash already marks this as
secondary.

`app/components/savings/goal_card_component.html.erb:53-58` — **P2** —
Footer line wraps on narrow cards. *Spacing — fixed widths break.*
Stack vertically (`flex-col gap-1`) or shorten to "+$1,531/mo to catch
up" (cents are noise at card density).

`app/components/savings/account_stack_component.html.erb:3-12` — **P2**
— 20px avatars with `text-[9px]` initials are unreadable. *Imagery —
intended sizes.* Bump to 24px or drop initials and rely on hover-title.

`app/components/savings/account_stack_component.html.erb:3` — **P1** —
`ring-2 ring-container` collapses in dark mode (ring color matches
page bg). *Depth — rings fake separation from the surface beneath.*
Use `ring-app` when the stack is on the page surface, `ring-container`
when on a card.

---

## 2. Show — header & action region

`app/views/savings_goals/show.html.erb:2-7` — **P1** — H1 + status
pill share a row; pill is `text-xs` next to `text-2xl`. *Hierarchy —
status is meta, not a peer of the name.* Move pill to the secondary
line. Long names ("Investment property downpayment") currently truncate
to "House …" on mobile because of the pill.

`app/views/savings_goals/show.html.erb:33-49` — **P1** — Edit (outline)
+ Add contribution (primary) + kebab. *Hierarchy — action pyramid.*
Pause/Resume/Complete/Archive are state changes hidden in the kebab
*after* the primary CTA. Promote Pause/Resume to a `ghost` button beside
Edit; keep Archive/Delete in the menu.

`app/views/savings_goals/show.html.erb:6-22` — **P2** — Subtitle joins
target amount + date + days-left with " · ". *Typography — line length.*
At 1440 ~80ch in one parse-heavy sentence. Stack: deck line under H1,
then meta on next line.

`app/views/savings_goals/show.html.erb:26-31` — **P2** — "Last
contribution 30 days ago" uses `mt-0.5` — ambiguous grouping with the
subtitle. *Spacing.* Increase to `mt-2` and give it a `clock-3` icon.

---

## 3. Show — alert banners

`app/views/savings_goals/show.html.erb:81-127` — **P1** — Three
mutually-exclusive banners use the wrong variants. *Color — variant
maps to intent.* Paused = `info` (blue), archived = `info` (blue),
catch-up = `warning` (yellow, correct). Paused is a *user-chosen
neutral state*, not info; archived is *historical*. Use a neutral
banner (`bg-surface-inset`) for paused + archived.

`app/views/savings_goals/show.html.erb:86-89,98-101` — **P0** —
Resume/Restore CTAs use raw `class="inline-flex items-center gap-1
rounded-md px-3 py-2 ... bg-inverse hover:bg-inverse-hover"`.
*Finishing touches — supercharge defaults.* Re-implements the primary
button by hand — focus ring, loading state, disabled state diverge.
Use `DS::Button` / `DS::Link` like the catch-up CTA at line 117-124
already does.

`app/views/savings_goals/show.html.erb:108` — **P2** — Catch-up title
"Save $1,531.25/mo to catch up" repeats verbatim in the CTA "Add
$1,531.25". *Hierarchy — redundant verbs.* Title states the rate; CTA
should state the verb ("Add this month" or "Add contribution").

---

## 4. Show — ring + projection

`app/views/savings_goals/show.html.erb:130-140` — **P1** — Ring card
shows percent in donut center AND `$1,320 of $2,400 · $1,080 to go`
underneath. *Cards — focal point.* Same redundancy as goal card but
louder. Strip the percent from the ring or strip the dollar line.

`app/views/savings_goals/show.html.erb:185` — **P2** — Projection arc
color picks green vs yellow from status. *Color — limited palette is a
feature.* For paused goals the projection still draws a confident
forecast (see Sabbatical screenshot). When paused, color the
projection `var(--color-gray-400)` and label it "If you resume."

`app/views/savings_goals/show.html.erb:179-201` — **P1** — Chart card
stacks heading + summary + legend above `min-h-[200px]` chart. *Spacing
— charts need room.* At 1280 the summary wraps to two lines and eats
chart height. Move the summary into the chart as an annotation, or
push it below as a caption.

`app/views/savings_goals/show.html.erb:142-158` — **P2** — Reached
celebration card = 64px disc icon + heading + body + archive button.
*Finishing touches — celebration moments deserve reward.* Add a subtle
pattern or a mini saved-progress chart so the "$15k done in 18 months"
story lands.

`app/views/savings_goals/show.html.erb:159-177` — **P2** — No-target-
date card uses identical chrome to the celebration card (h3 + p + sm
outline button). *Hierarchy — different intents should look different.*
Use `bg-green-500/10` accent for celebration only; keep no-target
neutral with smaller body copy.

---

## 5. Show — stats row + bottom row

`app/views/savings_goals/show.html.erb:209-229` — **P1** — Combo pace
card crams 5 facts on two lines: avg + /mo + target + delta. *Typography
— chunking.* The `text-2xl` + `text-sm` + `text-subdued` baseline-mix
forces left-to-right prose reading. Split into two side-by-side stats
(Avg vs Target) OR put the "Behind by" delta into a `text-warning`
pill on row 1 — current `text-subdued` hides the whole point.

`app/views/savings_goals/show.html.erb:233-237` — **P1** — Total
contributions card displays "12 · Across all accounts" — not linked,
not actionable. *Cards — make stats actionable.* Link to scroll/filter
the list below or replace with a more useful stat (median amount,
biggest this month). The "Across all accounts" label is also wrong for
single-account goals.

`app/views/savings_goals/show.html.erb:241-256` — **P2** — Two-column
`[1.6fr | 1fr]` clips both columns at 1280. *Spacing — relative weight
should match density.* Equal columns or stack at lg below 1280.

`app/views/savings_goals/_contributions_list.html.erb:10-44` — **P2** —
Row `px-2 py-2` is tight. *Spacing — list rows want breathing.* Bump
to `py-3`.

`app/components/savings/funding_accounts_breakdown_component.html.erb:4-10`
— **P1** — Stacked bar is `h-2`. *Dashboards — data viz needs minimum
size.* 8px is below the threshold where color differences register —
especially dark mode. Bump to `h-3` with `ring-inset ring-black/5`.

`app/components/savings/funding_accounts_breakdown_component.html.erb:18`
— **P2** — Meta line `text-[11px]` and percent `text-[10px]` are
off-scale. *Typography — type ramp.* The design system jumps 12→14→16.
Use `text-xs text-subdued` consistently.

`app/components/savings/funding_accounts_breakdown_component.html.erb:7`
— **P2** — Bar segment uses MD5(name) color. *Color — deterministic
identity is good, hierarchy is bad.* If two accounts hash close,
segments blur. Post-process to shift adjacent segments through the
palette.

---

## 6. New-goal modal — step 1

`app/views/savings_goals/_form_stepper.html.erb:9-19` — **P1** — Stepper
labels are equal-weight, only the fill differentiates. *Forms — progress
disclosure.* Make active circle 32px and inactive 28px so focus reads
through size, not just color.

`app/views/savings_goals/_form_stepper.html.erb:30-32` — **P2** — Avatar
preview at `size: "md"` (36px) vs xl (64px) on the show page. *Forms —
visual feedback should match destination.* Use `size: "lg"` (44px).

`app/views/savings_goals/_form_stepper.html.erb:43-53` — **P1** —
Target amount + target date in `grid-cols-2`. Money field uses styled
form chrome; date field uses native HTML date input. *Forms — side-by-
side requires same input language.* Match chrome on the date field or
stack them.

`app/views/savings_goals/_form_stepper.html.erb:56-87` — **P0** —
Funding accounts list has no helper text. *Forms — required fields
visible.* Empty submit shows a tiny error below the list. Add a hint
under the section label: "Choose where contributions will come from."

`app/views/savings_goals/_form_stepper.html.erb:64-74` — **P1** —
Checkbox + row click target is good but checked state is only a 16×16
checkmark. *Selectable cards.* Checked row should swap to
`bg-surface-inset` with a filled-blue checkbox; hover stays subtle.

`app/views/savings_goals/_form_stepper.html.erb:80` — **P2** — Balance
column matches account name weight (`text-sm font-medium`).
*Typography.* Bump balance to `text-secondary` so the eye distinguishes
selectable label from metadata.

`app/views/savings_goals/_form_stepper.html.erb:89-94` — **P2** — Notes
disclosure is right-aligned; breaks scanning. *Forms — progressive
disclosure.* Left-align like the rest of the form.

`app/views/savings_goals/_form_stepper.html.erb:96` — **P2** — Color
field is hidden in step 1; only edit form exposes the palette. *Forms —
silent state.* Either expose a small swatch row by the name field or
document the auto-pick.

---

## 7. New-goal modal — step 2

`app/views/savings_goals/_form_stepper.html.erb:99-123` — **P2** —
Review card weights "Funding accounts: 2" and "Suggested monthly:
$X/mo" equally. *Hierarchy — review should restate the commitment.*
Suggested monthly is the actionable fact; weight it as `text-base
text-primary`.

`app/views/savings_goals/_form_stepper.html.erb:125-152` — **P1** —
Initial-contribution disclosure has `include_blank: "Select account"`
on the select. If user opens it and forgets the select, submit silently
fails or zero-submits. *Forms — completeness.* Either require the
account when disclosure is open or auto-populate with the first linked
account.

`app/views/savings_goals/_form_stepper.html.erb:155-181` — **P2** —
Footer uses `hidden` (not `invisible`) on the Back button. *Forms —
nav visibility.* Continue button slides between steps. Use `invisible`
or `ml-auto` on Continue.

---

## 8. Edit modal

`app/views/savings_goals/_form_edit.html.erb:23-34` — **P1** — Color
palette = 6 24×24 swatches with `peer-checked:ring-2`. *Forms —
selectable swatches; imagery — tap targets.* 24px is below iOS 44px
threshold. Bump to 32px, add `aria-label` per radio, show a `check`
icon inside selected swatch.

`app/views/savings_goals/_form_edit.html.erb:38` — **P2** — Notes
textarea is 2 rows; stepper form's notes is 3 rows. *Forms — match
textarea sizing.* Use 3.

`app/views/savings_goals/_form_edit.html.erb:40-42` — **P2** — Bare
`f.submit` without explicit variant. *Buttons — supercharge defaults.*
Wrap in `DS::Button` like new modal does.

`app/views/savings_goals/edit.html.erb:1-7` — **P2** — Edit uses
default `DS::Dialog` title; new uses custom header with FilledIcon.
*Consistency — same logical action, different modal frame.* Match
headers or downgrade new.

---

## 9. Add-contribution modal

`app/views/savings_contributions/new.html.erb:11-23` — **P2** — Form
order is fine but the account select has `include_blank` even when
only one account is linked. *Finishing touches — smart defaults.* Pre-
select first account when there's only one.

`app/views/savings_contributions/new.html.erb:14` — **P2** — Money
field uses `hide_currency: true`. *Forms — currency clarity.* If the
goal's currency differs from primary, the user can mis-type. Show a
currency badge or put it in the label.

`app/views/savings_contributions/new.html.erb:25-27` — **P2** — Same
bare `f.submit` as edit modal. Wrap in `DS::Button`.

---

## 10. Contribution row — kebab + delete-confirm

`app/views/savings_goals/_contributions_list.html.erb:24-43` — **P1** —
Kebab only renders for `contribution.manual?`. Non-manual rows show an
invisible `w-9 h-9` placeholder. *Spacing — don't reserve space
silently.* Good for alignment but no affordance for "why no kebab." Add
a small lock icon or "Imported" tag in the source line.

`app/views/savings_goals/_contributions_list.html.erb:33-38` — **P1** —
`CustomConfirm` for delete uses `destructive: true`. *Modals —
destructive needs clear out.* Confirm cancel button text is "Cancel" or
"Keep," not modal-chrome "Close" — RUI calls out action-named cancel
buttons for destructive confirms.

---

## 11. Status pill — 5 variants

`app/components/savings/status_pill_component.rb:3-8` — **P1** — Two
variants share `bg-green-500/10 text-success` (on_track + reached); two
share `bg-surface-inset text-secondary` (no_target_date + paused).
*Color — each meaningful state needs distinct visuals.* Reached and
on-track are semantically different. Same for no-date and paused. Give
reached an amber/gold accent; give paused `text-subdued` to mute it.

`app/components/savings/status_pill_component.html.erb:1-4` — **P2** —
Pill `gap-1` is tight at `text-xs`. *Imagery — pill density.* Bump to
`gap-1.5` and `tracking-tight`.

`app/components/savings/status_pill_component.rb:6` — **P2** — Icon
for `no_target_date` is `infinity`. Reads as "unlimited" not "no
deadline." Use `calendar-x` or `calendar-question`.

---

## 12. Funding accounts breakdown

`app/components/savings/funding_accounts_breakdown_component.html.erb:1-2`
— **P2** — Empty state is one `<p>`. *Empty states — don't leave users
hanging.* Add a muted icon + CTA "Add your first contribution."

`app/components/savings/funding_accounts_breakdown_component.html.erb:12-26`
— **P2** — `space-y-3` between 3-line rows visually merges them.
*Spacing — list density.* Use `divide-y divide-subdued` or `space-y-4`.

---

## 13. Empty state — first run

`app/views/savings_goals/_empty_state.html.erb:3-29` — **P1** — Icon +
heading + body + button is functional but visually generic. *Empty
states — first-run sells the feature.* Replace the 32px target icon
with a muted hero illustration showing what a populated goal looks like.

`app/views/savings_goals/_empty_state.html.erb:19-26` — **P0** — When
`linkable_account_count == 0`, CTA goes to `new_account_path` with no
return path. *Empty states — guide the flow.* After account creation
the user lands on /accounts/new redirects, not /savings_goals. Add
`?return_to=/savings_goals` and a 2-step preview ("1. Connect 2. Set").

`app/views/savings_goals/_empty_state.html.erb:5-7` — **P2** — Icon
container `bg-surface-inset` differs from `bg-container` by ~5% L\*.
*Depth.* Use `bg-app` to invert the relief (card > inset > icon).

---

## 14. Mobile (375×667)

`app/views/savings_goals/index.html.erb:11` — **P1** — KPI strip
collapses to single-column. *Dashboards — mobile collapse.* Three
stacked full-width cards read as a notifications page. 2x2 with one
spanning, or compact "stat lines" (eyebrow + numeral inline).

`app/views/savings_goals/show.html.erb:33-78` — **P0** — Header action
group truncates the goal name on mobile (captured: "House …").
*Hierarchy — action bar must collapse.* Demote Edit + kebab to a sheet;
keep only "Add contribution" visible. Name must always show.

`app/views/savings_goals/show.html.erb:130` — **P1** — Stacked
ring/chart cards on mobile have no gap. *Spacing.* Add `space-y-3` on
the section so eye doesn't flow from "13%" into the chart axis.

`app/views/savings_goals/_form_stepper.html.erb:155-176` — **P2** —
Continue button isn't sticky on mobile. *Forms — mobile primary CTA.*
After selecting accounts, user scrolls back up to find Continue. Make
the footer `sticky bottom-0` on mobile.

---

## 15. Sidebar, breadcrumbs, header chrome

`app/views/savings_goals/index.html.erb:2-4` — **P2** — Subtitle "Your
savings accounts and the goals you're working toward" shows every
visit. *Typography — page subtitles carry decoration not info.* Replace
with current-period context ("$2,940 saved in May 2026") or hide after
first visit.

`config/locales/breadcrumbs/en.yml` (savings entry) — **P2** —
"Home › Savings › Goal name" on mobile wastes ~40px vertical. *Nav —
levels.* Drop "Home" on mobile or replace with a back chevron.

`app/views/savings_goals/show.html.erb:2` — **P2** — No explicit "Back
to Savings" link near the H1. *Nav — back affordance.* The breadcrumb
is chrome, not content. Add an arrow-left button next to the avatar.

---

## Top 10 ship-now

1. `show.html.erb:86-89,98-101` **P0** — Resume/Restore banner CTAs
   reimplement the primary button by hand. Replace with `DS::Button` so
   focus/hover/disabled match.
2. `show.html.erb:33-78` mobile **P0** — Header truncates goal name on
   mobile. Demote Edit + kebab to a sheet, keep only Add contribution.
3. `_form_stepper.html.erb:56-87` **P0** — Funding accounts list needs
   an explicit hint *before* the user clicks Continue.
4. `_empty_state.html.erb:19-26` **P0** — No-accounts state needs a
   return-to-savings_goals path after account creation + 2-step preview.
5. `index.html.erb:11-68` **P1** — Three equal-weight KPIs hide the one
   answering "am I winning?". Elevate "Goals on track" to primary card.
6. `status_pill_component.rb:3-8` **P1** — Reached + on-track share
   green; paused + no-target share grey. Give reached a gold accent;
   give paused a true muted look.
7. `show.html.erb:130-140` + `goal_card_component.html.erb:8-41` **P1**
   — Ring + numeric percent + dollar/target trio is redundant. Drop one.
8. `show.html.erb:81-127` **P1** — Paused + archived banners use
   info-blue. Use neutral; reserve info-blue for actual info.
9. `index.html.erb:92-119` **P1** — Search/chip toolbar mismatch. Cap
   search at `max-w-xs`, drop its border, add colored dots to chips.
10. `funding_accounts_breakdown_component.html.erb:4` **P1** — Stacked
    bar `h-2` is too thin. `h-3` + 1px inset ring lifts it from
    decoration to data.

---

## Closing notes

- Screenshots in `/Users/guillem.arias/Documents/gariasf/sure/audit-shots/`.
- No code edits made. Browser closed.
- Surfaces read from source rather than captured: add-contribution
  modal, contribution delete-confirm, archived show, no-accounts empty
  state, most mobile modal states. Findings still ground in real code.
