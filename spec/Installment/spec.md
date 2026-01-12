With the current implementation of loan details pop-up, it's not supported for installment plans.


Problem: Users struggle to add installment plans because the form asks for the “Total Loan Balance,” but their bank statement only shows the “Monthly Payment.” This forces them to do manual math on a calculator, frustrating them enough to stop using the feature. 

## Proposed Solution (brainstorm write-up): “Installment” flow inside Enter Loan Details

### 1) Core idea

We introduce an **Installment** mode inside **Enter Loan Details**, because installment users think in **monthly bills / terms**, not “total loan balance”.

**Goal:** automate **Current Balance** and **Original Loan Balance** during loan creation, so users don’t have to do calculator math.

---

## 2) UI structure: add a tab switch

Inside **Enter Loan Details**, add a simple tab switch:

* **General**
* **Installment** *(selected)*

This keeps the standard loan flow intact, while giving installment users a form that matches what they see on their statements.

---

## 3) Installment tab — proposed fields & layout

**Fields (top to bottom):**

1. **Account Name**
2. **Installment Cost** *(new)*
3. **Term** + **Payment Period** *(same row)*

   * Payment period options: **weekly, monthly, quarterly, yearly**
4. **Current Term** + **Payment Date** *(same row)*
5. **Current Balance** *(autofilled)*
6. **Original loan balance** *(autofilled)*
7. **Interest Rate** + **Rate Type**
8. **Create Account** (CTA)

**Layout change note:**
“Add new installment cost, move term to the top. Then, on the right side of the terms, add the payment period.”

---

## 4) Key UX insight: use “Current Term” to reduce friction

Instead of forcing users to compute the **first payment date**, we let them input what their statement literally shows:

* **Total term** (e.g., 6 months)
* **Current term** (e.g., “3 of 6”)

**Why this matters:** bank statements often show *current term vs total term*. If the statement says **“installment 3 of 6”**, asking users to figure out the date of installment #1 forces mental math (or calendar back-counting), which creates friction.

So the idea is:

* User inputs **Total Term** + **Current Term**
* System can **infer the first month/payment start**
* User can still **adjust the date** if needed

---

## 5) Autofill logic (balances)

**Autofill based on the top data:**

* **Current balance:** calculated from **installment cost + term + payment period**, using the schedule from the **first payment date** up to **today** (for an existing loan account).
* **Original balance:** total amount of money that will be paid over the entire life of the plan.

*(This directly addresses the earlier problem: users typically know “how much I pay” and “which installment number”, not the total outstanding principal.)*

---

## 6) Recurring transfer automation (nice-to-have / implementation note)

Set up **automatic recurring transfer transactions**:

* From a selected source account → to this loan account
* Starting from **First Payment Date (Expected date)**
* Repeats based on **Payment Period**
* Continues until the debt is settled

Open question noted:

* **“Can we do this using the existing recurring transactions feature?”**

---

## 7) Open questions captured in the brainstorm

1. **Payment date design:**
   “Use first payment field only OR use current term and then put another field to state the payment date?”
2. **Implementation reuse:**
   Can recurring transfers be powered by the **existing recurring transactions** system?

---

This will affect:
1. Enter loan details pop-up
2. Loan detail pageto accommodate better installment information 
3. Recurring transaction feature To support the installment transactions
