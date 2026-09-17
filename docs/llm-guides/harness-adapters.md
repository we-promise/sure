# Instruction adapters and maintenance

[AGENTS.md](../../AGENTS.md) contains the shared repository requirements and links
to detailed guides. Harness entry points load or direct readers to that guidance.
The [preservation map](instruction-preservation-map.md) records the sources,
history and intentional policy decisions behind this structure.

## Supported entry points

| Harness | Repository entry point | Loading behavior |
| --- | --- | --- |
| AGENTS-compatible tools | [AGENTS.md](../../AGENTS.md) | Read the root instructions and applicable linked guides. |
| Claude Code | [CLAUDE.md](../../CLAUDE.md) | Native `@AGENTS.md` import loads the canonical file at session start. |
| Cursor | [AGENTS.md](../../AGENTS.md), [project rules](../../.cursor/rules/) | Root guidance is supported natively; retained `.mdc` rules include shared guides with `@` references and preserve their existing applicability. |
| GitHub Copilot | [copilot-instructions.md](../../.github/copilot-instructions.md) | Repository-wide instructions explicitly direct the agent to read AGENTS and its applicable guides. |
| Junie | [AGENTS.md](../../AGENTS.md), [legacy guidelines](../../.junie/guidelines.md) | Current Junie discovers root AGENTS; the legacy entry point directs older clients to the same guidance. |
| Gemini Code Assist on GitHub | [config.yaml](../../.gemini/config.yaml) | Existing review configuration is retained unchanged; this is configuration, not an instruction adapter. |

Claude documents `@AGENTS.md` as an import from `CLAUDE.md`. Relative imports
resolve from the importing file. Using the import keeps both files ordinary text
files, including on Windows. [Claude Code memory documentation](https://code.claude.com/docs/en/memory#agentsmd)

Cursor supports root and nested `AGENTS.md` files. Project rules require the
`.mdc` extension, frontmatter and `@` file references to include shared content.
The adapters below use repository-root paths. [Cursor rules documentation](https://cursor.com/docs/rules)

Copilot's support for agent instruction files varies across GitHub, CLI and IDE
features. Keep its repository-wide entry point rather than relying on universal
`AGENTS.md` discovery. Its explicit read/follow link is an instruction to the
agent, not a claim that every Copilot surface automatically expands Markdown
links. Copilot CLI separately supports `@` relative-file imports in
`copilot-instructions.md`, `AGENTS.md` and `CLAUDE.md`.
[Copilot support matrix](https://docs.github.com/en/copilot/reference/custom-instructions-support),
[Copilot CLI instruction imports](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions)

Current Junie checks `.junie/AGENTS.md` first, then root `AGENTS.md`, then the
legacy `.junie/guidelines.md` or guidelines directory. Do not introduce a separate
`.junie/AGENTS.md` copy: it would take precedence over the shared root file. The
legacy adapter uses an explicit read/follow link rather than an undocumented
import directive. [Junie guidelines and memory](https://junie.jetbrains.com/docs/guidelines-and-memory.html)

Gemini Code Assist's `.gemini/config.yaml` controls GitHub review behavior. Its
`code_review.disable: true`, summary settings, severity threshold and ignore
patterns are preserved. Code Assist supports `.gemini/styleguide.md` for review
instructions, but this repository has no such file and this consolidation does
not add one. [Gemini Code Assist repository configuration](https://docs.cloud.google.com/gemini/docs/code-review/customize-repo-review)

Gemini CLI is a separate integration: it uses `GEMINI.md`, supports `@` imports,
and can change context filenames through `context.fileName` in `settings.json`.
There is no tracked Gemini CLI context configuration here; the review YAML does
not configure it. [Gemini CLI context documentation](https://geminicli.com/docs/cli/gemini-md/)

## Cursor applicability retained

These are the existing frontmatter values. `alwaysApply: true` retains global
loading even where a rule also lists globs. Empty description and globs on the
Stimulus rule preserve manual availability; adding either could change discovery.

| Rule | Shared content | `globs` | `alwaysApply` |
| --- | --- | --- | --- |
| [general-rules.mdc](../../.cursor/rules/general-rules.mdc) | [AGENTS.md](../../AGENTS.md) | `*` | `true` |
| [project-design.mdc](../../.cursor/rules/project-design.mdc) | [Architecture](architecture.md) | `*` | `true` |
| [testing.mdc](../../.cursor/rules/testing.mdc) | [Testing](testing.md) | `test/**` | `false` |
| [view_conventions.mdc](../../.cursor/rules/view_conventions.mdc) | [UI](ui.md) | `app/views/**,app/javascript/**,app/components/**/*.js` | `false` |
| [stimulus_conventions.mdc](../../.cursor/rules/stimulus_conventions.mdc) | [UI](ui.md) | empty | `false` |
| [ui-ux-design-guidelines.mdc](../../.cursor/rules/ui-ux-design-guidelines.mdc) | [Design system](design-system.md) | `app/views/**,app/helpers/**,app/javascript/controllers/**` | `true` |
| [api-endpoint-consistency.mdc](../../.cursor/rules/api-endpoint-consistency.mdc) | [API endpoint consistency](api-endpoint-consistency.md) | `app/controllers/api/v1/**/*.rb, spec/requests/api/v1/**/*.rb, test/controllers/api/v1/**/*.rb` | `false` |

The former `project-conventions.mdc` content now lives with architecture guidance;
the always-on architecture adapter keeps those conventions available. The generic
`cursor_rules.mdc` template and automatic `self_improve.mdc` rule-generation
trigger are retired, as recorded in the preservation map.

## Maintaining guidance

- Put common requirements in AGENTS and detailed explanations, examples and
  procedures in the appropriate shared guide. Keep adapters limited to loading
  and routing guidance.
- Update guidance when code, a workflow or a reviewed requirement changes.
  Verify examples against current files; keep links accurate and remove resolved
  temporary advice with an explanation in the change description.
- Review parallel entry points before changing a rule. Record intentional changes
  to mandatory checks, permission requirements or harness applicability explicitly.
- Change existing shared guidance before adding a new document or rule. Repeated
  code alone is not a trigger to generate more harness-specific policy files.
- When editing an adapter, verify its target and applicable loading syntax.
  Compare complete Cursor metadata values, rather than accepting substring
  matches that permit extra globs or duplicate values. The existing
  [API checker](../../test/support/verify_api_endpoint_consistency.rb) protects
  the API guide and its scoped adapter.

## Skills considered

[Adding a securities provider](adding-a-securities-provider.md) and
[gating a preview feature](gating-a-preview-feature.md) are bounded, repeatable
workflows and therefore plausible skill candidates. Skills have real ecosystem
support: both Copilot and Junie document the open format and shared
`.agents/skills/` locations.
[Copilot customization reference](https://docs.github.com/en/copilot/reference/customization-cheat-sheet),
[Junie agent skills](https://junie.jetbrains.com/docs/agent-skills.html)

No skill wrapper is introduced. The shared guides already make these procedures
available across harnesses; the repository also has
[Rails provider generators](../../lib/generators/provider/). A wrapper would add
another discovery and maintenance layer without a demonstrated invocation,
template-packaging or execution benefit. The wealth guides describe product
integration and operation, not a repository coding skill.

## Legacy helpers and local context

[bin/update_structure.sh](../../bin/update_structure.sh) is an optional generated
tree helper. Its ignored `.cursor/rules/structure.mdc` output is not a shared
policy source. The existing script writes `alwaysApply` to a different path and
then overwrites its generated header; repairing the generator is separate work.
The ignored `agent.mdc`, `dev_workflow.mdc` and `taskmaster.mdc` paths likewise
remain local/generated context.

[bin/codex-env](../../bin/codex-env) is a legacy Linux environment bootstrap,
not the standard setup procedure or a skill. It installs system packages,
changes PostgreSQL authentication, and can comment out the Ruby requirement
and mark Gemfiles assume-unchanged when versions differ. It remains unchanged;
use the maintained [development guide](development.md) for repository setup and
checks.
