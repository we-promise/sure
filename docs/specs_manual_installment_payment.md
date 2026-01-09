# Specification: Manual Installment Payments

| Attribute | Value |
| :--- | :--- |
| **Document Title** | Manual Installment Payments Specification |
| **Version** | 1.0 |
| **Author** | Manus AI (Senior Product Manager) |
| **Date** | January 4, 2026 |
| **Purpose** | Define the requirements for users to manually record installment payments within the `sure-indo` application, integrating with the new `Installment` entity. |

---

## 1. Overview

This document outlines the process for users to manually log a payment towards an existing `Installment` record. This is crucial for scenarios where automated payments fail, or users prefer to manually reconcile their installment liabilities. The goal is to ensure that manual payments correctly update the `Installment`'s status (e.g., `Total Spent to Date`, `Remaining Cost`, `Remaining Installments`) and are accurately reflected in the user's financial overview.

---

## 2. Decision: Transaction Type for Installment Payments

After analyzing the `sure-indo` repository's `Transaction`, `Entry`, and `Transfer` models, the most appropriate approach for handling installment payments (both manual and auto-generated) is to utilize the existing `Transaction` model with a specific `kind`.

### 2.1 Evaluation of Existing Transaction Kinds:

*   **`standard`**: While an installment payment is an expense, using `standard` might not fully capture its nature as a liability reduction. It would be included in budget analytics, which is desired, but lacks specific identification as a debt payment.
*   **`funds_movement`**: Not suitable, as this is for transfers between user accounts, not payments to external entities.
*   **`cc_payment`**: Not suitable, as this is specifically for credit card payments and is excluded from budget analytics.
*   **`loan_payment`**: This `kind` is defined as 
`A payment to a Loan account, treated as an expense in budgets`. This is the closest existing `kind` to an installment payment, as both represent a reduction of a liability and are considered expenses. However, installments are distinct from loans (no interest, fixed term).

### 2.2 Recommended Approach: New `Transaction` Kind `installment_payment`

To accurately represent installment payments and ensure correct financial reporting, a new `Transaction` kind, `installment_payment`, should be introduced. This `kind` will:

*   **Explicitly identify** transactions as installment payments.
*   Be **treated as an expense** in budget analytics, similar to `loan_payment`.
*   Allow for **specific UI/UX handling** and filtering.
*   Be linked to the `Installment` entity via the `transaction.installment_id` foreign key.

### 2.3 Rationale for Not Using a Separate Form for Installment Accounts

It is **not recommended** to create a separate form specifically for installment accounts. Instead, the existing transaction entry flow should be enhanced. This approach offers several benefits:

*   **Unified User Experience**: Users are already familiar with the transaction entry process, reducing cognitive load.
*   **Reduced Development Overhead**: Leverages existing UI components and validation logic.
*   **Consistent Data Model**: All payments (manual, auto-generated, installment, standard) flow through the same `Transaction` entity, simplifying reporting and aggregation.

---

## 3. Manual Payment Flow and Form Requirements

Users will record manual installment payments through the existing "Add Transaction" interface, with specific enhancements to link the payment to an `Installment`.

### 3.1 F1: Transaction Entry Enhancements

| ID | Feature | Description |
| :--- | :--- | :--- |
| **F1.1** | **Link to Installment** | When adding an Expense, a new optional field "Link to Installment" will allow users to select an active `Installment` record. |
| **F1.2** | **Auto-Populate Fields** | If an `Installment` is selected, the `Amount` field should auto-populate with the `Installment.installment_cost`. The `Category` should also auto-populate based on the `Installment`'s category (if defined). Users can override these auto-populated values. |
| **F1.3** | **Transaction Kind Assignment** | If an `Installment` is linked, the `Transaction.kind` will automatically be set to `installment_payment`. |
| **F1.4** | **Validation** | If an `Installment` is linked, the entered `Amount` should ideally match the `Installment.installment_cost`. A warning should be displayed if there's a significant discrepancy, but allow override. |

### 3.2 F2: Installment Status Updates

| ID | Feature | Description |
| :--- | :--- | :--- |
| **F2.1** | **Update Installment Progress** | Upon saving a `Transaction` with `kind: installment_payment` and a linked `Installment`, the `Installment`'s `Total Spent to Date`, `Remaining Cost`, and `Remaining Installments` must be updated. |
| **F2.2** | **Handle Overpayment/Underpayment** | If a manual payment is different from `Installment.installment_cost`, the system should adjust `Total Spent to Date` by the actual payment amount. This might lead to `Remaining Installments` being a non-integer or `Remaining Cost` being negative (overpaid). |

---

## 4. Data Model Updates

### 4.1 `Transaction` Model

*   **Add `kind` enum value**: `installment_payment`
*   **Add `installment_id`**: Foreign key to `Installment` (already defined in `sure_indo_installment_prd.md`).

### 4.2 `Installment` Model

*   **`has_many :transactions`**: Establish a `has_many` relationship to `Transaction` records where `kind: installment_payment`.

---

## 5. UI/UX Requirements

| ID | Requirement | Description |
| :--- | :--- | :--- |
| **UX.1** | **Transaction Form Field** | A clear, searchable dropdown or selector for linking an `Installment` within the Expense entry form. |
| **UX.2** | **Visual Confirmation** | After linking an `Installment`, a visual confirmation (e.g., a tag or badge) should appear next to the `Amount` and `Category` fields indicating they are pre-filled from the installment. |
| **UX.3** | **Installment Detail View** | The `Installment` detail view should clearly list all linked `Transaction` records, distinguishing between auto-generated and manually recorded payments. |
| **UX.4** | **Transaction List Indicator** | In the main transaction list, `installment_payment` transactions should have a distinct visual indicator (e.g., a specific icon or color) to differentiate them from `standard` expenses. |

---

## 6. Development Plan

1.  **Database Migration**: Add `installment_payment` to `Transaction.kind` enum and ensure `installment_id` foreign key is present.
2.  **`Installment` Model Update**: Add `has_many :transactions` association.
3.  **Transaction Form UI**: Implement the "Link to Installment" field with auto-population logic.
4.  **Transaction Save Logic**: Update `Transaction` creation to correctly assign `kind: installment_payment` and update `Installment` progress.
5.  **UI Updates**: Implement visual indicators in transaction lists and installment detail views.
6.  **Testing**: Comprehensive unit and integration tests for all new logic and UI components.
