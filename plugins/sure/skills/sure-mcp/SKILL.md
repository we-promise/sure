---
name: sure-mcp
description: >-
  Connect an AI assistant to Sure's MCP endpoint and use its financial
  tools safely: OAuth or static-token auth, reading accounts, transactions,
  budgets and statements, and making changes with dry_run and preview
  tokens. Use when an agent should analyze or tidy up a user's Sure
  finances.
---

# Sure over MCP

Reference: `docs/hosting/mcp.md`.

## Connect

Endpoint: `POST /mcp` on the Sure host (this plugin's `.mcp.json` uses
`http://localhost:3000/mcp`).

- **OAuth (recommended):** clients discover
  `/.well-known/oauth-protected-resource`, register with `POST /register`,
  sign in to Sure and get a `read_write` bearer token.
- **Static token:** set `MCP_API_TOKEN` and `MCP_USER_EMAIL` (an existing
  active user) on the `web` and `worker` services and send
  `Authorization: Bearer <MCP_API_TOKEN>`. The assistant then acts as that
  user's whole family, including write tools.

## Tools

Treat `tools/list` as the source of truth. Main groups:

- Read: `get_accounts`, `get_transactions`, `get_recurring_transactions`,
  `get_holdings`, `get_balance_sheet`, `get_income_statement`,
  `get_budget`, `get_merchants`, `get_tags`, `get_categories`, `get_rules`,
  `get_rule_options`, `search_family_files`
- Write: `update_transaction`, `create_tag`/`update_tag`,
  `create_category`/`update_category`/`delete_category`, `update_budget`,
  `create_goal`, `set_opening_balance`, transfer matching tools,
  `create_rule`/`update_rule`/`apply_rule`, `import_bank_statement`
- Preview-only (user opts in under Settings > Preferences): statement vault,
  valuations, insights and bills tools

## Working safely

1. Read before writing: resolve ids with `get_merchants`, `get_categories`
   and `get_accounts` instead of guessing.
2. Use `dry_run: true` where supported (`set_opening_balance`,
   transfer tools) and show the user the result.
3. Rules: `preview_rule` (or `create_rule`/`update_rule`) returns a
   `preview_token`; `apply_rule` needs it within 30 minutes and refuses if
   matches changed. Rules are saved inactive until applied. Hand-set
   values are kept unless `override_locked: true`.
4. Confirm with the user before deletes, budget changes, imports or
   applying rules. This is their financial data.
5. Notifications (no `id`) get `202` and a `tools/call` sent that way does
   not run.
