---
title: Fix remaining principal balance mismatch on installment overview
type: fix
date: 2026-01-22
---

# Fix remaining principal balance mismatch on installment overview

## Overview

The loan overview summary card shows "Remaining principal balance" using the account balance, while the installment overview calculates remaining from the installment schedule. For installment accounts these can diverge (for example, $0.00 in the summary card while the installment overview shows $90.00). The summary card should match the installment remaining amount and currency so the overview stays consistent.

## Problem Statement / Motivation

Users see conflicting remaining values in the same screen, which reduces trust and makes it unclear whether the loan is paid off. The summary card currently relies on `account.balance_money`, which can be zero even when the installment schedule still has a remaining balance. We need one authoritative definition for installment remaining principal on the overview.

## Proposed Solution

- Define remaining principal for installment accounts to use the same calculation as the installment overview (currently `Installments::OverviewComponent#remaining`).
- Introduce a shared method (for example, `Account#remaining_principal_money` or `Installment#remaining_money`) that returns the correct money object and currency.
- Update `app/views/loans/tabs/_overview.html.erb` to use the shared method when `account.installment.present?`.
- Keep non-installment loan behavior unchanged (continue using `account.balance_money`).

## Technical Considerations

- Data freshness: ensure the summary card and installment overview read from the same source at render time.
- Currency: use the same money object so formatting and currency symbol match the installment overview.
- Rounding: avoid floating math differences by reusing the same money object.
- Overpaid/negative balance behavior should align with the installment overview (clamp or show negative).

## Acceptance Criteria

- [ ] For installment accounts, the "Remaining principal balance" card equals the installment "Remaining" amount and currency.
- [ ] For non-installment loans, the summary card continues to use `account.balance_money`.
- [ ] The overview screen never shows a mismatch between summary remaining and installment remaining.
- [ ] Remaining values update consistently after editing installment details.
- [ ] Tests cover installment present/absent and mismatch regression cases.

## Success Metrics

- No user reports of remaining principal mismatch on installment overview.
- Internal QA screenshot checks show identical remaining amounts on the overview.

## Dependencies & Risks

- Risk: switching sources could reveal existing inconsistencies in installment calculations.
- Dependency: shared method must be accessible to both the overview summary card and installment component.

## Implementation Notes

- Update overview summary card:
  - `app/views/loans/tabs/_overview.html.erb`
- Add shared remaining method (choose one location):
  - `app/models/account.rb`
  - `app/models/installment.rb`
  - `app/helpers/accounts_helper.rb`
- Ensure installment overview uses shared method:
  - `app/components/installments/overview_component.rb`
  - `app/components/installments/overview_component.html.erb`
- Tests to add/update:
  - `test/components/installments/overview_component_test.rb`
  - `test/views/loans/overview_test.rb`
  - `test/fixtures/installments.yml`

## AI-Era Considerations

- If AI is used to update view logic, ensure a human review of the remaining balance definition.
- Re-run view/component tests after applying AI-generated changes.

## References & Research

- `app/views/loans/tabs/_overview.html.erb`
- `app/components/installments/overview_component.rb`
- `app/components/installments/overview_component.html.erb`
- `app/models/account.rb`
- `app/models/installment.rb`
- Screenshot: user-provided overview mismatch example
