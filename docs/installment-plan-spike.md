# Spike: a credit card EMI on the loan layer and the Bills installment feature

This is spike material for the discussion on
[we-promise/sure#3054](https://github.com/we-promise/sure/pull/3054). It answers
one question: can a credit card EMI with interest be modelled from the pieces
Sure already has, without a second amortisation engine, without new transaction
kinds and without future-dated entries?

## What the spike does

A purchase on a manual credit card is turned into an **installment plan**:

- The plan is a Bills **installment series** (`bill_type: installment`,
  `end_mode: after_count`, `end_after_count: 12`). Its occurrences are the
  twelve monthly charges the issuer posts. They are schedule rows, not ledger
  entries, so nothing is written into the ledger until a charge actually lands.
- The plan carries the loan terms (principal, annual rate, term and first due
  date) on the series, and the schedule comes from **the loan layer**:
  `Loan::AmortizationSchedule`, the same engine a loan uses. The plan and a loan
  cannot drift apart.
- The purchase the plan takes over stops counting: it leaves the budget and the
  balance, and the plan's charges take its place. This is the same rule a split
  parent follows.
- Each confirmed plan charge splits into **principal** and **interest**. The
  principal stays under the purchase category. The interest goes under the
  plan's financing category. The split uses the existing split engine.
- A purchase on a **synced** account is refused. There the provider's own
  transactions are the truth, and a plan on top of them would count the same
  money twice.

## How a user uses it

The action sits on the transaction, behind the Bills preview switch.

1. **Record the purchase as usual.** Use a manual credit card account and a
   plain expense with the right category. A linked account, a split row, an
   income row or a transfer cannot become a plan.
2. **Open the purchase and expand Settings.** Choose **Set up plan**.
3. **Enter the issuer's terms.** Give the annual interest rate, the number of
   monthly installments, the first due date and an interest category. The first
   date defaults to one month after the purchase. The dialog shows an estimate
   of the monthly payment and the total interest. The estimate comes from the
   loan engine, not from a second formula.
4. **Create the plan.** The bill page shows the monthly payment, the total
   interest, the total payable and the payoff date, all from the loan layer.
5. **The purchase leaves the budget and the card balance.** The plan appears
   under Bills → Installments with progress `0/N`, one row per due date, and
   each row knows its principal and interest split. While the plan owns the
   purchase, the generic Exclude, transfer and recurring-bill controls are
   hidden: the plan is the purchase's recurring record, so a second series or a
   manual toggle would count the same money twice.
6. **Post the issuer's charge each month.** The charge lands on the card as a
   normal expense. The matcher attaches it to that month's occurrence; the user
   confirms it, and the progress moves to `1/N`, `2/N`, and so on. A confirmed
   full charge splits automatically.
7. **Pay the card as usual.** A transfer from the bank account to the card
   settles the charge. The card balance returns to zero as the installments are
   paid, and the budget counts each charge when it posts.
8. **Change the terms before the first charge.** The bill page offers **Edit
   plan terms**. A change rebuilds the schedule and the projected occurrences.
   The purchase keeps its original amount; only the rate, term and first due
   date move. The option is available only while the plan is active, has no
   allocation at all, and has no skipped or missed installment. A payment, a
   suggestion or a user skip closes the editor.
9. **Let the plan finish.** At `N/N` the plan stays in history as ended. The
   purchase does not come back: the charges are its record.
10. **Cancel only while nothing has been paid.** Ending a plan before its first
    payment gives the purchase back to the budget and the balance. Once a
    payment is recorded the purchase stays out, because the charges replaced
    it. For the same reason a charged plan cannot be deleted; end it instead.

## Interest attribution

The issuer model is settled: card issuers normally replace the purchase with
monthly charges of principal plus interest. The plan follows that model. The
purchase leaves the balance, and the charges build it back up.

Interest attribution is also settled. The spike uses the existing split engine:

- A full, confirmed charge becomes two child entries. Principal goes to the
  purchase category; interest goes to the financing category.
- The plan page shows the scheduled split for each installment. The actual
  charge can differ from the estimate; the split keeps the scheduled interest
  and gives the rest to principal.
- A partial payment stays whole. Splitting part of a charge would attribute
  interest that the user has not paid yet.
- A charge with no interest category, zero interest, or the same category for
  both parts stays whole.
- Unlinking a payment removes a split only when both children still match the
  expected categories and amounts. A user-edited split is left alone.
- Split children are not match candidates. The matcher and the manual picker
  see the parent charge only, because the parent still carries the allocation.

The split changes reporting, not the card balance. In the example, the first
charge is $106.62 = $94.62 principal + $12.00 interest. The card balance is
$106.62 before and after the split.

## What is locked, and why

The plan copied the purchase terms when it started. Editing them later would
make the purchase disagree with the schedule that replaced it. The source
purchase therefore locks its name, date, amount, currency, account, category,
merchant and kind. It also hides the split, exclude, transfer, recurring and
delete actions. The server repeats every one of those checks.

The generic Bills editor keeps working for names, notes, links and categories.
It cannot change the plan's amount, account, currency, anchor, term or financing
terms. The dedicated **Edit plan terms** path is the only writer for those
fields, and it works only before anything is matched to the plan. A plan that
already took a payment keeps its schedule. To stop it, end the plan.

## Budget timing and the reserve

The plan reserves its open installments through the existing
`BudgetCategory#bills_reserved`. That reserve is a forecast of cash, not money
that has moved. It stays whole under the purchase category.

The split starts when the issuer's charge lands and the user confirms it. At
that point the principal and interest count in their own categories. This
decision has three results:

- The reserve never makes the financing category look spent before a charge
  exists.
- A partial payment remains a single commitment until the charge is complete.
- The total reserve and the actual spending do not double-count the same
  installment.

The spike does not split future reserves. A reserve has no ledger entry to
split, and a second forecast model would be a parallel engine. This is a
deliberate limit, not a missing hook. If the product later needs interest
forecast by category, the reserve calculation is the one place to change.

## What already existed (nothing here is new machinery)

| Need | What Sure already had |
| --- | --- |
| The payment plan | `RecurringTransaction` with `bill_type: installment` and `end_after_count`, the type the classifier already gives buy-now-pay-later bills. It brings occurrences, `installment_progress`, the matcher and the allocator with it. |
| The interest | `Loan::AmortizationMath`, `Loan::Simulator` and `Loan::AmortizationSchedule`. The spike calls them; it does not have a formula of its own. |
| Principal and interest reporting | `Entry#split!` and the split UI. The spike calls the same method and adds only one automatic splitter around it. |
| Money committed but not yet spent | `BudgetCategory#bills_reserved` already reserves the open occurrences of a series against the budget. |
| A superseded entry | `entries.excluded` already means "this entry no longer counts". The spike uses it and adds one narrow scope, `Entry.excluding_planned_purchases`, so a purchase a plan owns also leaves the balance. |
| The live estimate | A small preview action that calls `Loan::AmortizationSchedule` with the current form values. The dialog does not calculate an EMI in JavaScript. |

The plan's terms are the one new schema surface. The migration adds
`financed_principal_amount`, `financed_interest_rate`,
`financed_source_entry_id` and `financed_interest_category_id` to
`recurring_transactions`.

No new transaction kind. No entry dated into the future. No second amortisation
engine. No model that parallels `Loan`.

## The numbers

A $1,200 laptop on a manual credit card on 22 October 2026, converted into
twelve monthly instalments at 12% a year:

```
monthly        $106.62
total interest  $79.42
total payable $1,279.42
payoff         2027-10-22

# 1  2026-11-22  pay $106.62  principal $94.62  interest $12.00
# 2  2026-12-22  pay $106.62  principal $95.57  interest $11.05
...
#12  2027-10-22  pay $106.60  principal $105.54  interest  $1.06
```

The last instalment is a few cents lighter: the loan engine sizes it so the
balance lands on zero, and the plan's last occurrence expects that figure.

| Moment | Card balance | Budget |
| --- | --- | --- |
| Before the plan | $1,200 | $1,200 in October |
| After the plan | $0 | $0 in October, $1,279.42 reserved under the purchase category |
| First charge confirmed | $106.62 | $94.62 principal + $12.00 interest; the other 11 charges stay reserved |
| Twelve months later, all instalments charged and paid | $0 | $1,279.42 spent across principal and interest |

The same purchase without a plan, with one instalment charged on top of it,
shows **$1,306.62** of budget for one $1,200 laptop. That is the double count
the plan exists to prevent.

## Decisions

The following decisions are settled for this spike.

1. **The issuer replaces the purchase.** The purchase leaves the balance and
   the charges build it back up. The plan does not keep the purchase and add
   interest beside it.
2. **Interest uses the split engine.** Principal and interest go to different
   categories when a full charge is confirmed. The spike does not add a second
   transaction kind or a separate interest entry.
3. **The terms live on the Bills series.** A separate `Loan` account would bring
   a second liability onto the balance sheet and would need the purchase's debt
   to move with it. The spike keeps the terms on the series.
4. **The source purchase is locked.** Re-amortising a purchase after a charge
   would make the recorded charge disagree with the schedule. The user edits
   the plan terms before the first charge instead.
5. **The generic Bills editor is not a plan editor.** Schedule inputs are
   disabled there and refused on the server.
6. **The future reserve is not split.** The reserve stays a single cash
   commitment under the purchase category. Actual charges split when they land.
7. **The estimate runs on the server.** The preview action calls the loan
   engine. This keeps one formula for both the preview and the saved plan.

## Limits and follow-ups

These limits are known and accepted for the spike.

- Terms editing stops at the first allocation or closed occurrence. A plan with
  a suggestion or a user skip keeps its schedule.
- A charged plan cannot be deleted. The controller ends it instead.
- A partial payment stays whole until the charge is complete.
- A user who manually splits a plan charge before matching it hides the parent
  from the matcher. The normal path is to let the matcher and the allocator
  split the confirmed charge.
- The debt between charges is not on the balance sheet. The plan's schedule is
  the record of the principal still owed. Showing that debt up front is the
  same choice as a separate `Loan` account and remains open.
