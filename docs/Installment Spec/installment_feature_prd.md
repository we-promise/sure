# Product Requirements Document (PRD): Installment Tracking Module

| Attribute | Value |
| :--- | :--- |
| **Document Title** | Installment Tracking Module (Debt Integration) |
| **Version** | 1.0 |
| **Author** | Manus AI (Senior Product Manager) |
| **Date** | January 4, 2026 |
| **Scope** | Integration of fixed-term installment tracking into the existing `Loan` and `RecurringTransaction` framework within the `sure-indo` application. |

---

## 1. Introduction

### 1.1 Goal and Vision

The goal is to introduce a dedicated **Installment** feature under the existing Debt/Liability module. This feature will allow users to track fixed-term, fixed-amount payment plans (e.g., "Buy Now, Pay Later" schemes, product financing) that are distinct from traditional loans (which involve interest and amortization) but require similar long-term tracking. The vision is to provide users with a clear, automated view of their non-interest-bearing, fixed-term liabilities.

### 1.2 Context and Technical Approach

The `sure-indo` application currently uses the `Loan` model for interest-bearing debt and the `RecurringTransaction` model for general recurring payments. The Installment feature will be implemented as a new model, **`Installment`**, which will leverage the existing `RecurringTransaction` logic for scheduling and the `Entry` model for transaction logging.

The key distinction is that an **Installment** is a fixed-term commitment with a defined end date, which the existing `RecurringTransaction` model does not natively support in a structured way.

---

## 2. Goals & Objectives

| ID | Objective | Success Metric |
| :--- | :--- | :--- |
| **O1** | Enable tracking of fixed-term, fixed-amount liabilities. | 100% of user-defined installments are tracked with accurate remaining cost and payment count. |
| **O2** | Automate transaction generation. | Installment payments are automatically generated as `Transaction` entries on the scheduled date. |
| **O3** | Provide clear status and progress visualization. | The Payout Range (progress bar) is accurate and visible on the Installment detail view. |
| **O4** | Integrate seamlessly with existing financial reporting. | Installment payments are correctly reflected in the Balance Sheet (as a liability reduction) and Income Statement (as an expense). |

---

## 3. Functional Requirements

### 3.1 F1: Installment Creation (User Input)

The user must be able to create a new Installment record by providing the following data points:

| ID | Feature | Description | Technical Mapping |
| :--- | :--- | :--- | :--- |
| **F1.1** | **Service/Title** | Descriptive name of the item or service. | `Installment.name` (Title) |
| **F1.2** | **Number Of Installments** | Total number of payments in the plan. | `Installment.total_installments` (New field) |
| **F1.3** | **Payment Period** | Frequency of payment (Weekly, Monthly, Quarterly, Yearly). | `Installment.payment_period` (New field, similar to `RecurringTransaction` frequency) |
| **F1.4** | **First Payment Date** | The start date of the payment schedule. | `Installment.first_payment_date` (New field) |
| **F1.5** | **Installment Cost** | The fixed amount of each individual payment. | `Installment.installment_cost` (Money field) |
| **F1.6** | **Payment Method** | The account from which the payment will be made. | Relation to `Account` entity (e.g., `Installment.account_id`) |
| **F1.7** | **Auto-Generate Flag** | A flag to enable/disable the automatic generation of expense transactions. | `Installment.auto_generate` (Boolean) |

### 3.2 F2: System Calculation and Tracking

The system must automatically calculate and maintain the following properties:

| ID | Feature | Description | Calculation Logic |
| :--- | :--- | :--- | :--- |
| **F2.1** | **Total Costs** | The total financial commitment. | `[Installment Cost] * [Number Of Installments]` |
| **F2.2** | **Last Payment Date** | The projected date of the final payment. | Calculated by adding `[Number Of Installments] - 1` periods to the `[First Payment Date]`. |
| **F2.3** | **Total Spent to Date** | The cumulative sum of all linked `Transaction` entries. | Rollup/Sum of linked `Entry.amount` where `Entry.entryable_type = 'Transaction'` and `Transaction.installment_id = self.id`. |
| **F2.4** | **Remaining Cost** | The outstanding balance. | `[Total Costs] - [Total Spent to Date]` |
| **F2.5** | **Remaining Installments** | The number of payments still due. | `[Number Of Installments] - ([Total Spent to Date] / [Installment Cost])` |
| **F2.6** | **Payout Range** | The percentage of the total cost paid (progress bar). | `[Total Spent to Date] / [Total Costs]` |
| **F2.7** | **Time Elapsed** | Break down of time since `[First Payment Date]` into Weeks, Months, Quarters, and Years Elapsed. | Date difference calculations (e.g., `(Current Date - First Payment Date) / 30.44` for Months Elapsed). |
| **F2.8** | **Current Month Payment** | The sum of all payments due for this installment in the current calendar month. | Sum of projected/actual transactions for the current month. |

### 3.3 F3: Transaction Integration and Automation

| ID | Feature | Description | Integration Point |
| :--- | :--- | :--- | :--- |
| **F3.1** | **Automated Transaction** | On the scheduled date, a new `Transaction` (Expense) must be created with the amount equal to `[Installment Cost]`. | New background job leveraging `RecurringTransaction` scheduling logic. |
| **F3.2** | **Transaction Linkage** | The generated `Transaction` must be linked back to the parent `Installment` (e.g., via a new `Transaction.installment_id` foreign key). | `Transaction` model update. |
| **F3.3** | **Liability Tracking** | The `Installment` entity must be classified as a **Liability** (similar to `Loan`), and the automated transaction should reduce the liability balance. | New `Installment` model inherits from `Accountable` and is classified as a `liability`. |
| **F3.4** | **Transaction Naming** | The generated transaction name should be clear, e.g., "Installment: [Service/Title] ([X] of [Y])". | Transaction generation logic. |

---

## 4. Data Model Changes

### 4.1 New Model: `Installment`

This model will be the core of the new feature, inheriting from `ApplicationRecord` and likely including `Accountable` to manage its liability status.

| Field Name | Data Type | Notes |
| :--- | :--- | :--- |
| `name` | `string` | Title of the installment (e.g., "Beyond Running T-shirt"). |
| `total_installments` | `integer` | Total number of payments. (F1.2) |
| `payment_period` | `string` | Weekly, Monthly, Quarterly, Yearly. (F1.3) |
| `first_payment_date` | `date` | Start date of the plan. (F1.4) |
| `installment_cost` | `decimal` | Cost of a single payment. (F1.5) |
| `account_id` | `uuid` | Account from which payment is made. (F1.6) |
| `auto_generate` | `boolean` | Flag for automated transaction creation. (F1.7) |
| `total_cost` | *Virtual/Formula* | `installment_cost * total_installments`. (F2.1) |
| `last_payment_date` | *Virtual/Formula* | Calculated end date. (F2.2) |

### 4.2 Model Updates

| Model | Change | Notes |
| :--- | :--- | :--- |
| `Transaction` | Add `installment_id: uuid` | Foreign key to link payment back to the parent installment. (F3.2) |
| `Entry` | No direct change required. | `Entry` will be created for the `Transaction` (F3.1), and the `Entry` amount will be used for rollups (F2.3). |
| `RecurringTransaction` | No change. | The `Installment` model will handle its own scheduling logic, or a new `InstallmentScheduler` service will be created to manage the fixed-term nature, distinct from the open-ended `RecurringTransaction`. |

---

## 5. UI/UX Requirements

### 5.1 F4: User Interface

| ID | Requirement | Description |
| :--- | :--- | :--- |
| **UX.1** | **New Navigation** | Add a new section/tab under the existing Debt/Liability area titled "Installments". |
| **UX.2** | **Creation Form** | A dedicated form for F1.1-F1.7 inputs. The `Last Payment Date` (F2.2) should be displayed dynamically as the user enters `Number Of Installments` and `Payment Period`. |
| **UX.3** | **Detail View** | A dedicated view for each installment showing all calculated fields (F2.1-F2.8). |
| **UX.4** | **Progress Visualization** | The **Payout Range** (F2.6) must be displayed as a prominent, color-coded progress bar on the detail view and in the main Installment list. |
| **UX.5** | **Transaction Link** | On the Installment detail view, a list of all linked `Transaction` entries (F3.2) should be visible. |
| **UX.6** | **Debt Dashboard Integration** | The total remaining cost of all active installments should be included in the overall Debt/Liability dashboard summary. |
