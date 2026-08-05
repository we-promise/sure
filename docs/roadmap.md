<!-- roadmap:v1 -->

# Sure roadmap

This file is the curation and triage source for the public roadmap page. Keep
the phases and items in the order they should appear publicly. GitHub issues
and pull requests are supporting workflow links, not the roadmap source of
truth; a pull request review controls changes to this file and therefore to
the public roadmap.

The page reads this deliberately small Markdown format:

- Each phase starts with `## Phase: Name`, followed by one `Description:` line.
- Each item starts with `### Item: Name`, followed by `Status:`, `Description:`,
  and optionally `Issue: [label](https://github.com/...)` lines.
- Status must be one of `in_progress`, `planned`, or `exploring`.
- Keep metadata on one line. Unknown or incomplete items are omitted safely.

## Phase: Stabilize and polish the core

Description: Establish a stable, secure, polished foundation for the web product.

### Item: Reliability, performance, and technical-debt reduction

Status: in_progress
Description: Refactor duplicated code, improve provider abstractions, fix balance and sign inconsistencies, improve security, and establish a stable v1.0 foundation.

### Item: Web UX/UI polish and consistency

Status: in_progress
Description: Improve responsiveness, animations, optimistic UI, copy quality, wording, visual consistency, and general polish.

### Item: AI controls and transparency

Status: in_progress
Description: Add a first-class AI settings area with a master on/off switch and granular controls, keeping AI optional rather than forcing it on users.

### Item: Documentation and onboarding

Status: in_progress
Description: Improve generic and advanced guides, surface the documentation better, reorganize outdated material, and eventually support localized guidance.

### Item: Mobile app planning and delivery

Status: planned
Description: Build toward a polished iOS and Android app, while resolving the right timing and delivery approach after web stabilization.

### Item: Release cadence focused on quality

Status: in_progress
Description: Alternate stability, performance, and polish periods with feature-focused periods on a roughly quarterly or monthly rhythm.

## Phase: Expand personal-finance capability

Description: Add better tools for understanding money, planning decisions, and building long-term financial confidence.

### Item: Better AI integration and a first-class AI experience

Status: planned
Description: Make AI chat a dedicated page or workspace, allow it to navigate Sure’s UI, generate useful visualizations, and act as an assistant without replacing the traditional interface.

### Item: Transaction intelligence

Status: planned
Description: Use small, local, non-LLM machine-learning models to predict or categorize transactions.

### Item: Savings, retirement, and investment improvements

Status: planned
Description: Better separate everyday accounts from long-term savings with projections, fee impact, diversification and portfolio-health indicators, graphs, and retirement tooling.

### Item: Scenario simulation and sandbox mode

Status: planned
Description: Let users model hypothetical decisions, such as a major trip, and preview their short- and long-term financial effects.

### Item: Localization and country-specific finance support

Status: planned
Description: Add country-aware onboarding, categories, providers, account types, taxation, translations, and an international or multi-country mode.

### Item: Themes and customization

Status: planned
Description: Add additional themes and thoughtful customization as a lower-priority quality-of-life improvement.

## Phase: Open the platform carefully

Description: Extend Sure while keeping it understandable, controlled, and centered on user ownership.

### Item: External-agent integration and financial execution

Status: exploring
Description: Keep Sure as the system of record while approved external AI agents use its data and, with explicit approval, request or execute actions such as transfers or trades with strong opt-in controls, audit logs, and security.

### Item: Agent-assisted financial cleanup and memory

Status: exploring
Description: Support workflows such as reading receipts or email, reconciling purchases, and splitting transactions, while letting an external agent harness handle long-term memory and orchestration where appropriate.

### Item: Polished mobile ecosystem

Status: exploring
Description: Complete mobile parity and explore widgets, notifications, and Siri integration.

### Item: Improved macOS and desktop experience

Status: exploring
Description: Add native notifications and widgets while evaluating whether desktop belongs alongside web and mobile or should remain a separate effort.

### Item: Business finance support

Status: exploring
Description: Explore business finance only after personal finance is stable, likely as a separate app or product with different workflows, tax treatment, integrations, support expectations, and hosted or SMB offerings.
