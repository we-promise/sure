# Development guides

Start with [repository guidance](../../AGENTS.md), then read the guide for the work
being changed. These guides hold the detailed conventions and procedures.

| Task | Guide |
| --- | --- |
| Understand the domain and write Rails code | [Architecture and conventions](architecture.md) |
| Set up an environment, run checks or prepare a PR | [Development and verification](development.md) |
| Write behavioral tests and fixtures | [Testing](testing.md) |
| Change design tokens or `DS::*` primitives | [Design system](design-system.md) |
| Change views, components, CSS, Stimulus or localization | [UI](ui.md) |
| Add or modify an API v1 endpoint | [API endpoint consistency](api-endpoint-consistency.md) |
| Change provider imports, pending/FX metadata or diagnostics | [Provider sync guidance](providers.md) |
| Add a securities price provider | [Provider walkthrough](adding-a-securities-provider.md) |
| Gate or release a preview feature | [Preview-feature gating](gating-a-preview-feature.md) |
| Change goals, pledges or reconciliation | [Goals](goals.md) |

## External wealth integration

[Wealth history with an external agent harness](wealth-agent-harness.md) describes
Sure's read-only tool interface and the boundary with an external wealth system.
The [wealth blueprint](wealth-blueprint.md) is reference architecture for that
separate system. Its working-memory files, private document vault and operating
protocol apply to that external project, not to every change in this repository.

## Instruction maintenance

[Harness adapters](harness-adapters.md) documents discovery, supported imports,
scoped loading and legacy helpers. The [preservation map](instruction-preservation-map.md)
records the inventory, history, dispositions and intentional policy decisions for
the consolidation; it is an audit record rather than additional coding policy.
