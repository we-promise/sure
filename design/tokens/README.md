# Sure design tokens

This is where the design system actually lives. Tailwind reads from here, and any external tooling (Figma Tokens Studio, AI design tools, anything that shows up later) is meant to read the same JSON.

## Files

- `design/tokens/sure.tokens.json`: every token, hand-edited.
- `bin/tokens.mjs`: plain Node script. Compiles the JSON into Tailwind v4 CSS.
- `app/assets/tailwind/sure-design-system/_generated.css`: the build output. Generated, do not edit by hand.

## Workflow

```bash
# Edit a token:
$EDITOR design/tokens/sure.tokens.json

# Regenerate the CSS:
npm run tokens:build

# Commit both files together:
git add design/tokens/sure.tokens.json app/assets/tailwind/sure-design-system/_generated.css
```

`bin/setup` runs the build automatically on a fresh checkout.

## Versioning

The root `$version` field follows semver, scoped to the token contract:

- **Major** (`X.0.0`): breaking changes — token removed or renamed, value type changed, dark variant removed, semantic meaning changed.
- **Minor** (`1.X.0`): additive changes — new tokens, new `$extensions.sure.*` keys, new top-level groups.
- **Patch** (`1.0.X`): cosmetic / value tweaks that consumers don't need to know about — a hex shifts a few points without changing intent.

Bump it when you commit. External consumers (Tokens Studio, future Figma sync, etc.) read this to decide whether their cached snapshot is stale.

## Schema

The file uses the [W3C DTCG token format](https://design-tokens.github.io/community-group/format/): `$value`, `$type`, `$description`, `$extensions`. Tokens cross-reference via `{path.to.token}` placeholders.

```jsonc
{
  "color": {
    "white": { "$value": "#ffffff", "$type": "color" },
    "gray": {
      "500": { "$value": "#737373", "$type": "color" }
    },
    "success": {
      "$value": "{color.green.600}",
      "$type": "color",
      "$extensions": { "sure.dark": "{color.green.500}" }
    }
  }
}
```

### Top-level groups

| Key | Purpose |
|-----|---------|
| `font` | font-family stacks |
| `color` | base colors, semantic aliases (success, warning, destructive, shadow), full-scale ladders, alpha ladders |
| `budget` | budget-chart fills (need their own dark variants because Stimulus controllers reference them) |
| `border.radius` | corner radii |
| `shadow` | drop shadows, both light and dark variants |
| `animate` | named animations |
| `utility` | Tailwind `@utility` blocks: semantic surfaces, foregrounds, borders, button backgrounds, etc. |

### Custom `$extensions.sure.*`

| Extension | Where | What it does |
|-----------|-------|--------------|
| `sure.dark` | any token | Dark-mode override value. Same template syntax as `$value`. |
| `sure.alpha` | reserved | Currently unused; alpha is expressed inline via `{ref\|N%}`. Reserved for structured alpha if it's ever needed. |
| `sure.utility.prefix` | `utility.*` only | The Tailwind utility family (`bg`, `text`, `border`). Tells the build which `@apply` class to emit. |
| `sure.utility.raw` | `utility.*` only | A CSS property name (`background-color`, `box-shadow`, etc.) when the utility emits raw CSS instead of `@apply`. |
| `sure.compose` | `utility.*` only | Array of class names to `@apply`. For example, `bg-loader` is `["bg-surface-inset", "animate-pulse"]`. |

### Template strings

Anywhere a `$value` is a string:

- `{path.to.token}` resolves to `var(--path-to-token)` in the generated CSS.
- `{path.to.token|N%}` resolves to `--alpha(var(--path-to-token) / N%)` (Tailwind v4 alpha syntax).

The same syntax appears inside composite values like `shadow.xs.$value`: `"0px 1px 2px 0px {color.black|6%}"`.

### Alpha modifiers in views (`/N` syntax)

Tailwind v4's `class/N` modifier (`bg-warning/10`, `text-link/70`, etc.) only resolves on **theme colors** (anything declared under the top-level `color.*` group, which becomes `--color-*` in the generated CSS). It does **not** resolve on classes from this file's `utility.*` group, because those compile to static `@apply` blocks with no modifier-aware definition.

The mismatch is silent — Tailwind drops the unrecognized class and the element renders with no CSS for that property. Recently caught examples on `text-inverse/70`, `border-secondary/30`, and `bg-surface-inset/40` (all of which produced no class output).

Until the build script teaches custom utilities to be modifier-aware, the convention is:

- For alpha on a custom utility: pair the base class with `opacity-N`, e.g. `text-inverse opacity-70` instead of `text-inverse/70`.
- For alpha on a theme color: the `/N` modifier works as expected, e.g. `bg-warning/10`, `border-destructive/30`.

The pre-resolved alpha tints (`color.gray.tint-5`, `color.gray.tint-10`, `color.red.tint-5`, etc.) are theme colors, so `bg-gray-tint-5` and similar work as straight utilities and accept further `/N` modifiers.

### Adding a new token

1. Pick the right top-level group.
2. Add the `$value` (raw or `{ref}`) and `$type`.
3. If it should change in dark mode, add `$extensions.sure.dark`.
4. If it's a utility, add `$extensions.sure.utility.prefix` (or `raw`, or `compose`).
5. Run `npm run tokens:build`.
6. Look at the diff in `_generated.css` and confirm it's what you expected.
7. Commit both files.

### Edge cases the build script handles

- `color.gray.DEFAULT`: the `DEFAULT` segment is dropped in the CSS variable name (`--color-gray`, not `--color-gray-DEFAULT`). DTCG convention; matches Tailwind.
- `utility.border-divider`: the value is a plain class string (`border-tertiary`) instead of a `{ref}`. The build treats values without `{}` as raw `@apply` arguments.
- `utility.bg-overlay`: uses `sure.utility.raw: "background-color"` because it needs alpha rendering instead of `@apply`.
- `utility.bg-loader`: uses `sure.compose` to apply two utilities together (`bg-surface-inset animate-pulse`).
- `utility.button-bg-ghost-hover`: its dark value is a multi-class string (`bg-gray-800 text-inverse`), not a single ref. The build accepts both forms.

## Consumers

- Rails / Tailwind: via the generated CSS, automatically.
- Lookbook reference page: `/design-system/inspect/design_tokens/*` reads `sure.tokens.json` at request time.
- External tools (Figma Tokens Studio, AI design tools, etc.): point them at this file.

If a consumer wants a different shape, transform the JSON in their tooling rather than editing the source here.
