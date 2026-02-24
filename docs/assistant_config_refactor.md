# Refactor: Move prompt/config off Family (PR #951)

## Owner feedback (summary)

- Storing prompts on `Family` is the wrong place, especially with configurable backends.
- Prefer an architecture that supports multiple Assistant implementations (Builtin, External, future OpenClaw) and keeps each backend’s config in one clear place.

## Current state (PR #951)

- **On `families`**: `custom_system_prompt`, `custom_intro_prompt`, `preferred_ai_model`, `openai_uri_base`.
- **Usage**: `Assistant::Configurable` and `Assistant::Builtin` read these from `chat.user.family`; `Provider::Registry.openai_for_family(family)` uses `openai_uri_base` + `preferred_ai_model`.

## Proposed architecture: per–assistant-type configuration

Store configuration **per family and per assistant type**, not on `Family` itself.

### Option A: Dedicated table per backend (e.g. builtin only for now)

- **Table**: `builtin_assistant_configs` (or `family_builtin_assistant_configs`)
  - `family_id` (uuid, unique)
  - `custom_system_prompt` (text)
  - `custom_intro_prompt` (text)
  - `preferred_ai_model` (string)
  - `openai_uri_base` (string, optional – custom endpoint for this family’s builtin)
  - timestamps
- **Associations**: `Family has_one :builtin_assistant_config`; config is created/updated when the family uses the builtin assistant.
- **Pros**: Simple, explicit, no jsonb. When you add OpenClaw, you add `openclaw_assistant_configs` (or similar) with that backend’s fields.
- **Cons**: One new table per backend (acceptable if backends are few and their configs differ).

### Option B: Single generic table for all backends

- **Table**: `assistant_configurations`
  - `family_id` (uuid)
  - `assistant_type` (string, e.g. `"builtin"`, `"external"`, `"openclaw"`)
  - `config` (jsonb) – each backend defines its own keys (e.g. builtin: `custom_system_prompt`, `custom_intro_prompt`, `preferred_ai_model`, `openai_uri_base`)
  - unique on `[family_id, assistant_type]`
  - timestamps
- **Pros**: One table for all current and future backends; adding OpenClaw doesn’t require new migrations for config storage.
- **Cons**: Less type-safe; each Assistant implementation must know how to read/write its slice of `config`.

### Recommendation

- **Short term (refactor PR #951)**: Option A is the smallest, clearest change: one table `builtin_assistant_configs` (or `family_builtin_assistant_configs`), move the four fields off `families`, and keep the same UI/flow but backed by this table. Family stays free of prompt/LLM details.
- **When adding OpenClaw (or another backend)**: Either add a similar table for that backend (Option A style) or migrate to a single `assistant_configurations` table (Option B) if you prefer one place for all backend configs.

## Refactor steps (for PR #951)

1. **Migration**
   - Create `builtin_assistant_configs` (or chosen name) with the four columns above.
   - Backfill from existing `families` columns (if any).
   - Remove `custom_system_prompt`, `custom_intro_prompt`, `preferred_ai_model`, `openai_uri_base` from `families` in a follow-up migration (or same migration if you’re okay with a brief downtime/backfill window).

2. **Models**
   - `Family has_one :builtin_assistant_config` (and `accepts_nested_attributes_for` if you want to keep the same form).
   - Validations and `custom_openai_endpoint?` move to `BuiltinAssistantConfig` (or the new model name).

3. **Assistant / provider**
   - `Assistant::Configurable` (used by Builtin): take `family` and resolve config via `family.builtin_assistant_config` (with defaults when nil or blank).
   - `Chat.default_model(family)`: use `family.builtin_assistant_config&.preferred_ai_model` (and fallbacks) instead of `family.preferred_ai_model`.
   - `Provider::Registry.openai_for_family(family)`: use `family.builtin_assistant_config` for `openai_uri_base` and `preferred_ai_model` (or keep a thin wrapper on Family that delegates to `builtin_assistant_config` so call sites don’t all need to know the new model).

4. **Settings UI**
   - `Settings::AiPromptsController` and the form: keep the same UX but strong-params and persistence go to the new model (e.g. `family.builtin_assistant_config`), not `family` attributes.

5. **Tests**
   - Update specs/fixtures to create `builtin_assistant_config` where you currently set family prompt/model/uri columns; update any assertions that read those from `family`.

## Result

- Prompts and builtin-specific LLM config live in a dedicated place, not on `Family`.
- Adding another Assistant type (e.g. OpenClaw) doesn’t pollute Family; you add that backend’s config table or a row in `assistant_configurations` and wire that type’s `config_for` / provider logic to it.

This doc can be dropped into the PR or an issue and adjusted to match whatever naming (e.g. `family_builtin_assistant_configs`) and migration strategy the team prefers.
