# Subcategory Budget Inheritance

## Overview

This feature allows subcategories to share their parent category's budget instead of requiring individual budget allocations. This is useful when you want to track spending across multiple subcategories without setting strict limits for each one individually.

## How It Works

### Setting Up Budget Inheritance

1. **Create a parent category with a budget**
   - For example: "Food & Groceries" with a $1000 budget

2. **Create subcategories**
   - For example: "Restaurants", "Groceries", "Coffee"

3. **Choose how to allocate budgets:**

   **Option A: Individual Limits (Traditional)**
   - Set specific budget for each subcategory
   - Example: Restaurants $400, Groceries $500, Coffee $100
   - Each subcategory tracks against its own limit

   **Option B: Shared Budget (New Feature)**
   - Leave subcategory budget empty (or set to $0)
   - Subcategory will share the parent's budget pool
   - Parent budget is available to all subcategories that inherit

   **Option C: Mixed Approach**
   - Some subcategories with individual limits
   - Some subcategories sharing parent budget
   - Example: Restaurants $400 (fixed), Groceries and Coffee share remaining $600

## Budget Calculation Examples

### Example 1: All Subcategories Share Parent Budget

**Setup:**
- Parent "Food" budget: $1000
- Subcategories: Restaurants ($0), Groceries ($0), Coffee ($0)

**Spending:**
- Restaurants: $300
- Groceries: $200
- Coffee: $50

**Result:**
- Parent shows: $450 remaining ($1000 - $550 spent)
- Each subcategory shows: $450 remaining (shared pool)

### Example 2: Mixed Individual and Shared Budgets

**Setup:**
- Parent "Food" budget: $1000
- Restaurants: $400 (individual limit)
- Groceries: $0 (shared)
- Coffee: $0 (shared)

**Spending:**
- Restaurants: $300
- Groceries: $200
- Coffee: $50

**Result:**
- Restaurants: $100 remaining ($400 - $300)
- Parent shows: $350 remaining ($1000 - $400 ring-fenced - $250 shared spending)
- Groceries shows: $350 remaining (shared pool)
- Coffee shows: $350 remaining (shared pool)

## UI Indicators

- **Form placeholder:** Subcategories show "Shared" as placeholder text when editing
- **Display indicator:** Budget amounts show "(shared)" label for inheriting subcategories
- **Tooltip:** Hovering over subcategory budget field shows "Leave empty to share parent's budget"

## Technical Details

### How to Make a Subcategory Inherit

Simply set or leave the subcategory's budgeted spending to $0 or empty. The system automatically detects this and shares the parent's budget.

### Budget Ring-Fencing

When you set an individual budget for a subcategory, that amount is "ring-fenced" from the parent budget. Only that subcategory can use it, and it won't be available to other subcategories or the parent.

### Calculations

- **Parent available budget** = Parent budget - Ring-fenced amounts - All spending
- **Inheriting subcategory available** = Parent's available budget (shared)
- **Individual subcategory available** = Individual budget - Individual spending

## Benefits

1. **Flexibility:** Track spending without rigid per-category limits
2. **Simplicity:** Don't need to pre-allocate budgets for every subcategory
3. **Mixed approach:** Combine fixed limits with flexible spending as needed
4. **Real-time sharing:** All inheriting subcategories see the same shared pool
