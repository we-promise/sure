# User Stories: Manual Installment Payments

| Attribute | Value |
| :--- | :--- |
| **Document Title** | User Stories: Manual Installment Payments |
| **Version** | 1.0 |
| **Author** | Manus AI (Senior Product Manager) |
| **Date** | January 4, 2026 |
| **Purpose** | Outline user-centric requirements for recording manual payments towards existing Installment liabilities. |

---

## 1. Core Transaction Type & Data Model

| ID | User Story | Acceptance Criteria |
| :--- | :--- | :--- |
| **US1.1** | As a **developer**, I want to introduce a new `Transaction` kind called `installment_payment`, so that installment payments can be distinctly identified and processed. | - The `Transaction` model has a new `kind` enum value: `installment_payment`.<br>- `installment_payment` transactions are treated as expenses in financial reports. |
| **US1.2** | As a **developer**, I want to ensure `Transaction` records can be linked to an `Installment` record, so that payments can be attributed to their respective installment plans. | - The `Transaction` model has an `installment_id` foreign key.<br>- The `Installment` model has a `has_many :transactions` association. |

---

## 2. Transaction Entry Form Enhancements

| ID | User Story | Acceptance Criteria |
| :--- | :--- | :--- |
| **US2.1** | As a **user**, I want to be able to link an expense to an existing `Installment` when adding a new transaction, so that my manual payment is correctly associated with the installment plan. | - The expense entry form includes an optional field "Link to Installment".<br>- This field is a searchable dropdown/selector displaying active `Installment` records. |
| **US2.2** | As a **user**, when I select an `Installment` in the transaction form, I want the `Amount` and `Category` fields to auto-populate, so that I can quickly record the payment with minimal effort. | - Selecting an `Installment` auto-fills the `Amount` with `Installment.installment_cost`.<br>- Selecting an `Installment` auto-fills the `Category` with the `Installment`'s associated category.<br>- I can override the auto-populated `Amount` and `Category`. |
| **US2.3** | As a **user**, I want the system to automatically mark a transaction as an `installment_payment` when I link it to an `Installment`, so that its type is correctly recorded. | - If an `Installment` is linked, the `Transaction.kind` is set to `installment_payment` upon save. |
| **US2.4** | As a **user**, if I enter an `Amount` that differs significantly from the `Installment.installment_cost` for a linked installment, I want to be warned, so that I can confirm the discrepancy or correct my input. | - A warning message appears if the entered `Amount` deviates by more than a defined threshold (e.g., 5%) from `Installment.installment_cost`.<br>- I can choose to proceed with saving the transaction despite the warning. |

---

## 3. Installment Status Updates

| ID | User Story | Acceptance Criteria |
| :--- | :--- | :--- |
| **US3.1** | As a **user**, when I record a payment for an `Installment`, I want the `Installment`'s `Total Spent to Date` to be updated, so that I can see how much I've paid so far. | - Saving an `installment_payment` transaction increases the `Installment.total_spent_to_date` by the transaction's `Amount`. |
| **US3.2** | As a **user**, when I record a payment for an `Installment`, I want the `Installment`'s `Remaining Cost` to be updated, so that I know my outstanding balance. | - Saving an `installment_payment` transaction decreases the `Installment.remaining_cost` by the transaction's `Amount`. |
| **US3.3** | As a **user**, when I record a payment for an `Installment`, I want the `Installment`'s `Remaining Installments` count to be updated, so that I know how many payments are left. | - Saving an `installment_payment` transaction decreases the `Installment.remaining_installments` count by 1 (if the amount matches `installment_cost`) or proportionally if the amount differs. |
| **US3.4** | As a **user**, I want the `Installment`'s `Payout Range` to reflect the updated payment progress, so that I can visually track my progress. | - The `Installment.payout_progress` percentage is recalculated and updated after each payment. |

---

## 4. UI/UX for Visibility

| ID | User Story | Acceptance Criteria |
| :--- | :--- | :--- |
| **US4.1** | As a **user**, I want to see a clear visual indicator for `installment_payment` transactions in the main transaction list, so that I can easily distinguish them from other expenses. | - `installment_payment` transactions have a distinct icon or color-coded badge in the transaction list. |
| **US4.2** | As a **user**, I want to see all linked payments (both manual and auto-generated) when viewing an `Installment`'s details, so that I have a complete history of payments for that plan. | - The `Installment` detail view displays a list of all associated `Transaction` records.<br>- Each linked transaction clearly indicates if it was auto-generated or manually recorded. |
| **US4.3** | As a **user**, when I view the transaction form after linking an `Installment`, I want to see a visual confirmation that fields were auto-populated, so that I understand the system's assistance. | - Auto-populated `Amount` and `Category` fields show a subtle visual cue (e.g., light gray text, a small icon) indicating their source. |

---

## 5. Development Tasks (High-Level)

These are not user stories but high-level tasks to guide implementation.

| ID | Task | |
| :--- | :--- | :--- |
| **DT5.1** | Create database migration to add `installment_payment` to `Transaction.kind` enum. | |
| **DT5.2** | Update `Transaction` model with `belongs_to :installment` and `Installment` model with `has_many :transactions`. | |
| **DT5.3** | Implement UI for "Link to Installment" field in transaction form. | |
| **DT5.4** | Implement auto-population logic for `Amount` and `Category` based on selected `Installment`. | |
| **DT5.5** | Implement validation/warning for `Amount` discrepancy. | |
| **DT5.6** | Implement logic to update `Installment` status fields (`total_spent_to_date`, `remaining_cost`, `remaining_installments`, `payout_progress`) upon saving a linked `installment_payment` transaction. | |
| **DT5.7** | Implement visual indicators for `installment_payment` in transaction lists. | |
| **DT5.8** | Implement display of linked transactions in `Installment` detail view. |
