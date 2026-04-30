# Sure design tokens

Single source of truth for the design system. Anything Tailwind / Figma / future tools should consume points back here.

## Files

- `sure.tokens.json` — every token, hand-edited.
- `../tools/tokens/build.mjs` — plain Node script that compiles the JSON into Tailwind v4 CSS.
- `../app/assets/tailwind/sure-design-system/_generated.css` — build output. **Generated, do not edit by hand.**

## Workflow

```bash
# Edit a token:
$EDITOR tokens/sure.tokens.json

# Regenerate the CSS:
npm run tokens:build

# Commit both files in the same change:
git add tokens/sure.tokens.json app/assets/tailwind/sure-design-system/_generated.css
```

`bin/setup` runs the build automatically on a fresh checkout.

## Schema

The file follows the [W3C DTCG token format](https://design-tokens.github.io/community-group/format/) — `$value`, `$type`, `$description`, `$extensions`. Tokens reference each other via `{path.to.token}` placeholders.

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
| `color` | base colors, semantic aliases (success/warning/destructive/shadow), full-scale ladders, alpha ladders |
| `budget` | budget-chart fills (need their own dark variants in Stimulus controllers) |
| `border.radius` | corner radii |
| `shadow` | drop shadows (light + dark variants) |
| `animate` | named animations |
| `utility` | Tailwind `@utility` blocks (semantic surfaces, foregrounds, borders, button backgrounds, etc.) |

### Custom `$extensions.sure.*`

| Extension | Where | What it does |
|-----------|-------|--------------|
| `sure.dark` | any token | Dark-mode override value. String following the same template syntax as `$value`. |
| `sure.alpha` | reserved | Currently unused — alpha is expressed inline via `{ref\|N%}`. Reserved for structured alpha if needed later. |
| `sure.utility.prefix` | `utility.*` only | The Tailwind utility family (`bg`, `text`, `border`). Tells the build which `@apply` class to emit. |
| `sure.utility.raw` | `utility.*` only | Set to a CSS property name (e.g. `background-color`, `box-shadow`) when the utility emits raw CSS instead of `@apply`. |
| `sure.compose` | `utility.*` only | Array of class names to `@apply` (e.g. `["bg-surface-inset", "animate-pulse"]` for `bg-loader`). |

### Template strings

Anywhere a `$value` is a string:

- `{path.to.token}` — resolves to `var(--path-to-token)` in the generated CSS.
- `{path.to.token|N%}` — resolves to `--alpha(var(--path-to-token) / N%)` (Tailwind v4 alpha syntax).

The same syntax appears inside composite values like `shadow.xs.$value`: `"0px 1px 2px 0px {color.black|6%}"`.

### Adding a new token

1. Pick the right top-level group.
2. Add the `$value` (raw or `{ref}`) and `$type`.
3. If it should change in dark mode: add `$extensions.sure.dark`.
4. If it's a utility: add `$extensions.sure.utility.prefix` (or `raw`, or `compose`).
5. `npm run tokens:build`.
6. Verify the diff in `_generated.css` looks right.
7. Commit both files.

### Edge cases captured today

- `color.gray.DEFAULT` — `DEFAULT` segment is dropped in the CSS variable name (`--color-gray`, not `--color-gray-DEFAULT`). DTCG convention; matches Tailwind's naming.
- `utility.border-divider` — value is a plain class string (`border-tertiary`) rather than a `{ref}`. The build treats values without `{}` as raw `@apply` arguments.
- `utility.bg-overlay` — uses `sure.utility.raw: "background-color"` because it needs alpha rendering rather than `@apply`.
- `utility.bg-loader` — uses `sure.compose` to apply two utilities together (`bg-surface-inset animate-pulse`).
- `utility.button-bg-ghost-hover` — its dark value is a multi-class string (`bg-gray-800 fg-inverse`) rather than a single ref. The build accepts both.

## Consumers

- **Rails / Tailwind** — via the generated CSS, automatically.
- **Lookbook reference page** — `/design-system/inspect/design_tokens/*` reads `sure.tokens.json` at request time.
- **External tools** (Figma Tokens Studio, AI design tools, etc.) — point them at this file. The schema is open and stable.

If a consumer needs a different shape, prefer transforming the JSON in their tooling rather than mutating the source.
