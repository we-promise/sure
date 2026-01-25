# Brainstorm: Installment as a First-Class Accountable Type

**Date:** 2026-01-24
**Status:** Decided
**Decision:** Approach 1 — New `Installment` accountable type

---

## What We're Building

Promote `Installment` from a secondary model attached to `Loan` into its own first-class accountable type (`accountable_type: "Installment"`), classified as a `"liability"`.

This separates two fundamentally different financial products:
- **Loan**: Amortizing debt with interest rates, APR, rate types, and term calculations
- **Installment**: Fixed-payment schedules without interest (phone plans, furniture payments, buy-now-pay-later)

---

## Why This Approach

### Current Problems
1. **Tight coupling** — Installment logic is embedded inside `LoansController` and the Loan form via a dual-mode pattern, making both features harder to extend
2. **Wrong abstraction** — Installments don't have interest rates, amortization, or rate types. Forcing them into a Loan model adds unnecessary complexity
3. **Feature blocking** — Adding installment-specific features (analytics, notifications, payment tracking) requires touching Loan code and risking regressions

### Benefits of Separation
- Clean, independent feature development for installments
- Loan model becomes simpler (single responsibility)
- Follows existing codebase patterns (each accountable type is its own model)
- PostgreSQL `classification` generated column handles liability grouping automatically

---

## Key Decisions

1. **New accountable type** — `Installment` joins `TYPES` array in `Accountable` concern
2. **Classification: liability** — Installment accounts appear alongside Loans and CreditCards in liability views
3. **Dedicated controller** — `InstallmentsController` replaces the dual-mode logic in `LoansController`
4. **Data migration** — Existing installment-mode loans (`accounts.subtype = "installment"`) migrate to the new type
5. **No shared concerns yet** — Follow YAGNI; extract `PaymentSchedulable` only if a third type needs it later
6. **Breaking change accepted** — Clean migration over backwards-compatibility hacks

---

## Scope of Changes

### Models
- New `Installment` model (accountable, classification: liability)
- Move installment columns into the new `installments` table (as accountable backing table)
- Clean up `Loan` model (remove installment-related code)
- Update `Account` model (remove installment-specific helpers or move to new model)
- Update `Accountable::TYPES` array
- Update the `classification` generated column SQL

### Controllers
- New `InstallmentsController` with create/update/destroy
- Clean up `LoansController` (remove installment mode)

### Views & Components
- New installment form (simpler than loan form — no interest/rate fields)
- Move `Installments::OverviewComponent` and `PaymentScheduleComponent` to work with new type
- Update "new account" UI to point Installment to new controller
- Update account detail views

### Database
- Migration: add `Installment` to the `classification` generated column CASE statement
- Migration: restructure installments table (becomes accountable backing table)
- Data migration: move existing installment-mode loan accounts to new type

### Other
- Update `RecurringTransaction` association (currently has `installment_id`)
- Update transaction `extra["installment_id"]` references
- Update i18n locale files
- Update Stimulus `loan_form_controller.js` (split or create `installment_form_controller.js`)

---

## Open Questions

1. **Subtypes for Installment** — Should it have subtypes? (e.g., phone_plan, furniture, bnpl, other)
2. **Interest-bearing installments** — Some BNPL plans do charge interest. Should we support an optional interest field, or keep that as a Loan?
3. **Provider sync** — How should SimpleFIN/Plaid imports handle installment-like accounts? (Probably still import as Loan and let users convert manually)

---

## Rejected Approaches

- **Approach 2 (Shared concern)**: Over-engineering risk. Extract `PaymentSchedulable` only when a third type needs it.
- **Approach 3 (OtherLiability subtype)**: Doesn't solve the problem — just moves the mess. OtherLiability becomes a grab-bag.
