---
name: Finantreta (Sure)
description: Personal finance for Brazilian individuals — achromatic precision, semantic color earned not spent
colors:
  near-black: "#0B0B0B"
  canvas: "#F7F7F7"
  container: "#FFFFFF"
  surface-inset: "#F0F0F0"
  text-primary: "#171717"
  text-secondary: "#737373"
  text-subdued: "#9E9E9E"
  border-secondary: "#E7E7E7"
  border-primary: "#CFCFCF"
  success: "#078C52"
  warning: "#DC6803"
  destructive: "#EC2222"
  info: "#1570EF"
typography:
  display:
    fontFamily: "'Geist', system-ui, sans-serif"
    fontSize: "clamp(1.5rem, 3vw, 2rem)"
    fontWeight: 700
    lineHeight: 1.1
    letterSpacing: "-0.02em"
  headline:
    fontFamily: "'Geist', system-ui, sans-serif"
    fontSize: "1.25rem"
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: "-0.01em"
  title:
    fontFamily: "'Geist', system-ui, sans-serif"
    fontSize: "1rem"
    fontWeight: 600
    lineHeight: 1.4
  body:
    fontFamily: "'Geist', system-ui, sans-serif"
    fontSize: "0.875rem"
    fontWeight: 400
    lineHeight: 1.5
  label:
    fontFamily: "'Geist', system-ui, sans-serif"
    fontSize: "0.75rem"
    fontWeight: 500
    lineHeight: 1.4
    letterSpacing: "0.01em"
rounded:
  md: "8px"
  lg: "10px"
  xl: "12px"
  full: "9999px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "24px"
  2xl: "32px"
components:
  button-primary:
    backgroundColor: "{colors.near-black}"
    textColor: "{colors.container}"
    rounded: "{rounded.lg}"
    padding: "8px 12px"
  button-primary-hover:
    backgroundColor: "#242424"
    textColor: "{colors.container}"
    rounded: "{rounded.lg}"
    padding: "8px 12px"
  button-secondary:
    backgroundColor: "#E7E7E7"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.lg}"
    padding: "8px 12px"
  button-secondary-hover:
    backgroundColor: "{colors.surface-inset}"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.lg}"
    padding: "8px 12px"
  button-ghost:
    backgroundColor: "transparent"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.lg}"
    padding: "8px 12px"
  button-destructive:
    backgroundColor: "{colors.destructive}"
    textColor: "{colors.container}"
    rounded: "{rounded.lg}"
    padding: "8px 12px"
  form-field:
    backgroundColor: "{colors.container}"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.md}"
    padding: "8px 12px"
---

# Design System: Finantreta (Sure)

## 1. Overview

**Creative North Star: "The Ledger Room"**

Dense information made navigable through order, not decoration. Think of a well-run accountant's office: every figure in its place, hierarchies communicated through structure and scale rather than ornament. Nothing competes with the data. The interface earns attention by disappearing.

The color system is deliberately achromatic. Near-black (`#0B0B0B`) handles every primary action and primary text role. Semantic colors — green for gains, red for losses, yellow for caution, blue for information — appear only when they carry meaning. Their rarity is the system's core communicative mechanism: when something turns green, it means something. An interface that splashes color freely trains users to ignore it.

Typography works hard. Geist's geometric-humanist character gives the system precision without coldness. The display step carries monetary figures — account balances, net worth — with the weight they deserve. Labels and metadata recede into secondary gray. The eye lands on the number that matters.

This system explicitly rejects: dense table UIs that present every datum at equal visual weight (the spreadsheet trap); corporate banking interfaces that bury actions under institutional chrome; and generic fintech palettes that reach for navy-and-gold the moment the category is "finance."

**Key Characteristics:**
- Achromatic primary palette; semantic hues earned, not spent
- Geist: humanist precision, comfortable at small sizes, authoritative at display
- Barely-there elevation: 1px border overlays plus 6% shadow, not theatrical depth
- Generous vertical rhythm; crowding is forbidden even under data density
- Dual-theme system (light / dark) with full token coverage; not an afterthought

## 2. Colors: The Ledger Room Palette

A neutral-first palette where the absence of a persistent accent is the design decision. Color communicates state, not brand.

### Primary
- **Near Black** (`#0B0B0B`): Primary actions (buttons, nav indicators, text on light), inverse text on dark surfaces. Not pure black — the 0B tint keeps it from feeling inkjet-flat.
- **Canvas** (`#F7F7F7`): App surface. The page background in light mode. Warm enough to distinguish from the colder container white without any perceptible tint.
- **Container White** (`#FFFFFF`): Card and panel backgrounds. Sits one step above canvas, defining containment without a shadow in most contexts.

### Secondary
- **Success Green** (`#078C52`): Positive balances, gains, confirmed transactions, healthy states. Dark mode maps to `#32D583` (green.400).
- **Warning Amber** (`#DC6803`): Budget pressure, caution states. Not alarmist, not critical.
- **Destructive Red** (`#EC2222`): Negative deltas, losses, delete actions. High contrast; never softened with tint on the action itself.
- **Info Blue** (`#1570EF`): Links, informational badges, syncing states.

### Neutral
- **Text Primary** (`#171717`): Body copy, field values, table content. Gray-900, not black.
- **Text Secondary** (`#737373`): Labels, captions, metadata. Gray-500.
- **Text Subdued** (`#9E9E9E`): Placeholders, disabled text, empty states. Gray-400.
- **Border Secondary** (`#E7E7E7`): Default field and card borders (approximation; actual token is `alpha-black-200` = 10% opacity black, which renders near this value on white).
- **Border Primary** (`#CFCFCF`): Stronger separators, hover-emphasized borders.
- **Surface Inset** (`#F0F0F0`): Input backgrounds, inset panels, skeleton loaders.

### Named Rules
**The Earned Color Rule.** Semantic colors (green, red, yellow, blue) appear only when they carry financial meaning. No decorative use. No accent usage. If a screen looks monochromatic at a glance, that is correct behavior.

**The Near-Black Rule.** Primary buttons and active nav indicators use `#0B0B0B`, not a color. The product identity is not expressed through hue. It is expressed through clarity.

## 3. Typography

**Display Font:** Geist (with system-ui, -apple-system, Helvetica Neue, Arial fallback)
**Body Font:** Geist (same stack; weight and size carry all hierarchy)
**Mono Font:** Geist Mono (account numbers, ISPB codes, CNPJ/CPF fields, code)

**Character:** Geist is geometric-humanist: precise and efficient at small sizes, composed at display sizes. Its optical evenness makes tabular financial data comfortable to scan. No serif pairing needed; the weight range (400 to 700) provides sufficient contrast within the single family.

### Hierarchy
- **Display** (700, clamp(1.5rem–2rem), line-height 1.1, tracking −0.02em): Monetary totals, net worth, account balance on the detail view. The number that answers "how am I doing?"
- **Headline** (600, 1.25rem / 20px, line-height 1.3, tracking −0.01em): Section headers, page titles, modal headings.
- **Title** (600, 1rem / 16px, line-height 1.4): Card titles, account names, group headings.
- **Body** (400, 0.875rem / 14px, line-height 1.5): Transaction descriptions, form field values, table rows. Max line length 65–75ch where prose occurs.
- **Label** (500, 0.75rem / 12px, line-height 1.4, tracking +0.01em): Form field labels, column headers, metadata chips, timestamps.

### Named Rules
**The Scale Contrast Rule.** Consecutive hierarchy steps must differ by at least 1.25×. A body-to-title step of 14px → 16px (1.14×) is too flat; only the weight change (400 → 600) saves it. Avoid collapsing the scale further.

**The Mono Boundary Rule.** Machine-generated identifiers — bank codes (COMPE, ISPB), account numbers, transaction IDs — always render in Geist Mono. They are not prose; they must not reflow as prose.

## 4. Elevation

Flat by default. Surfaces rest flush against each other; depth is not an ambient property of the UI. Shadows appear only when two surfaces need clear separation — a card floating above a background, a dropdown above its trigger. They never decorate.

The system uses a distinctive pattern: every shadow token includes a 1px border overlay (`0px 0px 0px 1px rgba(11,11,11,0.05)`) combined with a soft ambient drop. This creates the impression of a physical edge without a visible border-color rule. In dark mode, the overlay inverts to a white alpha tint at equivalent opacity.

### Shadow Vocabulary
- **xs** (`0px 1px 2px 0px rgba(11,11,11,0.06)`): Form fields at rest, minimal lift for inline elements.
- **sm** (`0px 1px 6px 0px rgba(11,11,11,0.06)`): Ambient container separation; the default card shadow when used.
- **md** (`0px 4px 8px -2px rgba(11,11,11,0.06)`): Dropdowns, popovers, floating panels.
- **lg** (`0px 12px 16px -4px rgba(11,11,11,0.06)`): Dialogs, modals.
- **shadow-border-\*** (any of the above + `0px 0px 0px 1px rgba(11,11,11,0.05)`): Preferred over bare shadows. Adds the physical-edge feel without a separate border declaration.

All values at 6% black opacity. Not heavier. If it looks like a shadow, it's too strong.

### Named Rules
**The Flat-By-Default Rule.** Surfaces are flat at rest. Shadows appear only as a structural response to elevation, not to add visual interest. If you find yourself adding a shadow for aesthetics, remove it.

**The No-Theatrical-Depth Rule.** If the shadow is visible at a glance from a normal reading distance (arm's length, 72dpi screen), it is too dark. The 6% opacity limit is not a starting point for negotiation.

## 5. Components

### Buttons

Confidence without loudness. The primary button is near-black: authoritative, impossible to miss, impossible to misread as decorative.

- **Shape:** Rounded corners (10px / `rounded-lg`) for md size. 8px for sm, 12px for lg. Slightly rounded, never pill-shaped on action buttons; `rounded-full` is reserved for badge contexts.
- **Primary** (`bg: #0B0B0B`, `text: #FFFFFF`): 12px horizontal padding, 8px vertical (md). Font-medium, 14px. Hover darkens to `#242424`. Disabled uses gray-500 bg.
- **Secondary** (`bg: #E7E7E7`, `text: #171717`): Same padding. Hover to `#F0F0F0`.
- **Destructive** (`bg: #EC2222`, `text: white`): Hover to red-600 (`#EC2222` → `#C91313`). Only for irreversible actions with explicit confirmation.
- **Outline** (transparent bg, border-secondary): Hover adds surface-inset bg. Secondary hierarchy.
- **Ghost** (transparent, no border): Hover adds container-inset bg. Tertiary hierarchy, sidebar actions, icon-adjacent labels.
- **Icon-only variants:** 32px (sm), 44px (md), 48px (lg) square touch targets.
- **Focus:** 4-step ring in `rgba(11,11,11,0.2)` (alpha-black-200). Keyboard-navigable, high contrast.

### Chips / Pills

Two modes. Same component, different contexts.

- **Marker mode** (uppercase, 10–11px, rounded-md, tracking-wider): Stage indicators (Beta, Canary, NEW, PRO). Not for status.
- **Badge mode** (normal case, 12–14px, rounded-full): Transaction status (Pending, Confirmed), category tags, account kind labels. Use semantic tone aliases: `:success` → green, `:warning` → amber, `:error` → red, `:info` → indigo, `:neutral` → gray.
- **Soft style** (default): tinted background + matching text + light border. Legible without competing with surrounding content.
- **Filled style**: solid tone color, white text. High-emphasis status only.

### Cards / Containers

Not the default answer. Use containment only when content genuinely needs a grouped boundary.

- **Corner Style:** 8–10px radius (md / lg token). Subtly rounded; not so round they look like badges.
- **Background:** Container white (`#FFFFFF`) in light; gray-900 (`#171717`) in dark.
- **Shadow Strategy:** `shadow-border-sm` for cards that float above the canvas. No shadow for sections that are structurally part of the page.
- **Border:** None explicit; the 1px border overlay in `shadow-border-*` provides the edge.
- **Internal Padding:** 16–24px. Never compress to 8px; if it feels tight, the content belongs inline, not in a card.

### Inputs / Fields

- **Style:** `.form-field` — rounded-md (8px), border-secondary, shadow-xs, bg-container. The chevron for `<select>` is SVG-inlined.
- **Focus:** shadow-none + 4px ring in alpha-black-200 (`rgba(11,11,11,0.2)`), 300ms transition. The ring replaces the shadow; total border presence stays constant.
- **Error:** border-destructive (red-500), supporting text in destructive color.
- **Disabled:** text-subdued (gray-400), bg unchanged.
- **Field label:** 12px / label weight (500), text-secondary. Always above the input, never placeholder-only.

### Navigation

- **Sidebar nav items:** Ghost style, full-width, text-secondary at rest. Active state uses `nav-indicator` token (near-black in light, white in dark) for a left-aligned indicator strip — the only sanctioned use of a structural accent line.
- **Tab groups:** Pill-style tab container in surface-inset (gray-50 bg). Active tab lifts to container white with shadow-xs. Smooth 300ms transition.
- **Topbar:** Container white, border-secondary bottom edge. No shadow; the border separates it.

### Account List Item (Signature Component)

The primary unit of the accounts index. Renders account logo (initial letter or bank SVG), account name, institution name or Brazilian bank ISPB/code, subtype label, and balance.

- Bank identification for Brazilian accounts displays as: `short_name` inline + `• CODE · ISPB XXXXXX` in text-subdued below.
- Logo fallback: `DS::FilledIcon` — filled circle, brand hue if defined, initial letter of the bank's short name. Not a generic user avatar.
- Balance at rest: display weight (700), text-primary. Negative balance: text-destructive.

## 6. Do's and Don'ts

### Do:
- **Do** use `text-primary`, `text-secondary`, `text-subdued` for all text. Never raw hex or gray-N directly in view templates.
- **Do** reach for semantic color only when it carries financial meaning: green for gains, red for losses, yellow for caution, blue for informational.
- **Do** use `shadow-border-*` variants instead of bare shadow tokens. The 1px border overlay is structural.
- **Do** render monetary figures in Display weight (700). The number that matters must look like it matters.
- **Do** use Geist Mono for machine identifiers: bank codes (COMPE/ISPB), account numbers, CNPJ/CPF, transaction IDs.
- **Do** give inputs a visible label above, always. Placeholder-only labels disappear on interaction.
- **Do** keep card padding at minimum 16px. Financial data needs room to breathe.
- **Do** use `icon` helper (never `lucide_icon` directly) for all icon usage in Rails templates.

### Don't:
- **Don't** use a persistent brand accent color. The primary action is near-black. If you feel the need for a colored CTA, the hierarchy problem is elsewhere.
- **Don't** render dense tables with equal visual weight on every cell. That is the spreadsheet trap. Establish hierarchy through size, weight, and secondary color before reaching for layout.
- **Don't** use `border-left` or `border-right` greater than 1px as a colored accent stripe on list items or cards. The nav indicator is the only structural accent line in the system. If you want a callout, use a background tint.
- **Don't** use gradient text (`background-clip: text`). Financial figures are data; they carry no aesthetic meaning.
- **Don't** use glassmorphism, backdrop-filter, or blur effects as decoration. This system is opaque and precise.
- **Don't** import shadow values heavier than the 6% opacity limit. If the shadow is visible across the room, it's wrong.
- **Don't** copy the corporate banking UI pattern: action-burying navigation, redundant confirmation modals, three-tap journeys for a one-tap task.
- **Don't** use a navy background, gold accent, or gradient dashboard widgets. That is the generic fintech reflex and it belongs to someone else's product.
- **Don't** omit dark mode coverage when adding a new token. The `sure.dark` extension is required on every new color utility.
