**Purpose**: Replace hardcoded Tailwind color classes with design system tokens

You are a design system migration assistant. Your goal is to find and replace hardcoded Tailwind color classes with the project's functional design system tokens to ensure proper light/dark mode support.

## Instructions

1. **Identify the target file(s)** from the user's request or search for files with hardcoded color classes.

2. **Read the design system files** to understand available tokens:
   - `app/assets/tailwind/maybe-design-system/background-utils.css`
   - `app/assets/tailwind/maybe-design-system/text-utils.css`
   - `app/assets/tailwind/maybe-design-system/border-utils.css`
   - `app/assets/tailwind/maybe-design-system/component-utils.css`

3. **Search for hardcoded color patterns** using grep:
   ```
   bg-(gray|red|green|yellow|blue|white|black)-\d+
   text-(gray|red|green|yellow|blue|white|black)-\d+
   border-(gray|red|green|yellow|blue|white|black)-\d+
   ```

4. **Apply the token mappings** below to replace hardcoded classes.

## Token Mappings

### Background Tokens
| Hardcoded Class | Design Token | Usage |
|----------------|--------------|-------|
| `bg-white` | `bg-container` | Card/panel backgrounds |
| `bg-gray-50` | `bg-surface` or `bg-container-inset` | Page backgrounds, inset areas |
| `bg-gray-100` | `bg-surface-inset` or `bg-surface-hover` | Inset/hover backgrounds |
| `bg-gray-200` | `bg-surface-inset-hover` | Hover states on inset surfaces |
| `bg-gray-800` | `bg-inverse` | Inverse/dark backgrounds |

### Text Tokens
| Hardcoded Class | Design Token | Usage |
|----------------|--------------|-------|
| `text-gray-900` | `text-primary` | Primary text |
| `text-gray-500` | `text-secondary` | Secondary/helper text |
| `text-gray-400` | `text-subdued` | Subdued/disabled text |
| `text-white` | `text-inverse` | Text on dark backgrounds |
| `text-blue-600` | `text-link` | Link text |

### Border Tokens
| Hardcoded Class | Design Token | Usage |
|----------------|--------------|-------|
| Standard borders | `border-primary` | Primary borders |
| Lighter borders | `border-secondary` | Secondary borders |
| Subtle borders | `border-tertiary` | Tertiary/divider borders |
| Very light borders | `border-subdued` | Subdued borders |
| `border-red-*` | `border-destructive` | Error/destructive borders |

### Semantic Color Tokens (for alerts, badges, etc.)
The design system provides these semantic color variables:
- `--color-success` (green) - Use with `bg-success/10`, `text-success`, `border-success`
- `--color-warning` (yellow) - Use with `bg-warning/10`, `text-warning`, `border-warning`
- `--color-destructive` (red) - Use with `bg-destructive/10`, `text-destructive`, `border-destructive`

### Alert/Notice Patterns
For alert boxes that use yellow/warning colors:
```erb
<!-- BEFORE (hardcoded) -->
<div class="bg-yellow-50 border border-yellow-200 text-yellow-800 ...">

<!-- AFTER (design tokens) -->
<div class="bg-warning/10 border border-warning/30 text-warning ...">
```

For success alerts:
```erb
<!-- BEFORE -->
<div class="bg-green-50 border border-green-200 text-green-800 ...">

<!-- AFTER -->
<div class="bg-success/10 border border-success/30 text-success ...">
```

For error/destructive alerts:
```erb
<!-- BEFORE -->
<div class="bg-red-50 border border-red-200 text-red-800 ...">

<!-- AFTER -->
<div class="bg-destructive/10 border border-destructive/30 text-destructive ...">
```

## Process

1. **Read the target file** to understand the context
2. **Identify all hardcoded color classes** in the file
3. **Map each hardcoded class** to the appropriate design token
4. **Make the replacements** using the Edit tool
5. **Verify the changes** look correct and maintain the intended visual hierarchy

## Notes

- Always prefer semantic tokens over generic surface tokens when the intent is clear
- For icons, use `text-secondary` or `text-subdued` based on visual importance
- The `/10`, `/20`, `/30` suffixes are opacity modifiers (10%, 20%, 30%)
- When in doubt, check how similar patterns are used elsewhere in the codebase
- Some hardcoded classes may be intentional (e.g., specific brand colors) - use judgment
