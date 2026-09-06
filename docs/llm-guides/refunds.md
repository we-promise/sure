# Purchase refunds

Refunds use `Transaction.kind = "refund"`. They retain the incoming entry's
negative bank amount and posting date. Income statements treat them as signed
expense reductions, never income. A purchase of 1,000 followed by an 800 refund
therefore contributes 200 to spending. A refund received in a later month reduces
that month's spending, potentially below zero.

The optional `refund_of_id` links a refund to its original purchase. Several
refunds may reference one purchase. A combined refund can be split using the
existing transaction split workflow before linking each child to a purchase.
Linking copies the purchase category but does not change either bank amount.
Sender names, amounts and currencies do not need to match. Purchase detail net
cost uses each refund's dated exchange rate and displays unavailable when a rate
cannot be obtained. It includes only refunds accessible to the viewer.

Preview users can mark, link and undo refunds from transaction details. The
existing preview preference gates these entry points; already classified refunds
remain correctly accounted for when preview is turned off. Read-only and
annotation-only account shares cannot change classification.

Use `Transaction#mark_as_refund!(purchase: nil)` and `#clear_refund!` for manual
classification, preserving enrichment locks and provider metadata. Unpaired
credit-card payments may be corrected to refunds; undo restores their prior
kind. Auto-transfer matching and recurring-income identification exclude refunds.
Unlink before splitting linked transactions or creating transfers. Deleting a
purchase leaves its credits classified as unlinked refunds.

Expense aggregates must preserve signs: do not wrap their sums in `ABS`, clip
refund-only categories to zero or move negative spending into income. Budget
visualization percentages can be zero while actual spending remains negative.
The bank-direction `Entry#classification` is retained for API compatibility;
financial reports and refund filters use the transaction kind.

The nullable indexed self-reference is introduced by
`20260906120000_add_refund_of_to_transactions.rb`. No historical transactions are
automatically reclassified. Migration and runtime verification follow the
[development guide](development.md).
