require "test_helper"

class Category::MergerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @other_family = families(:empty)
  end

  test "merge only reassigns and deletes categories inside the current family" do
    target = create_category(@family, "Cross Family Merge Target")
    source = create_category(@family, "Cross Family Merge Source")
    source_child = create_category(@family, "Cross Family Merge Child", parent: source)
    transaction = create_transaction_for(@family, source)
    budget = create_budget(@family, 1.month.from_now.to_date.beginning_of_month)
    target_budget_category = create_budget_category(budget, target, 8)
    source_budget_category = create_budget_category(budget, source, 12)

    other_target = create_category(@other_family, target.name)
    other_source = create_category(@other_family, source.name)
    other_child = create_category(@other_family, source_child.name, parent: other_source)
    other_transaction = create_transaction_for(@other_family, other_source)
    other_budget = create_budget(@other_family, 1.month.from_now.to_date.beginning_of_month)
    other_source_budget_category = create_budget_category(other_budget, other_source, 30)

    other_family_snapshot = -> {
      {
        target_exists: Category.exists?(other_target.id),
        source_exists: Category.exists?(other_source.id),
        child_parent_id: other_child.reload.parent_id,
        transaction_category_id: other_transaction.reload.category_id,
        source_budgeted_spending: other_source_budget_category.reload.budgeted_spending
      }
    }

    assert_no_changes other_family_snapshot do
      merger = Category::Merger.new(
        family: @family,
        target_category: target,
        source_categories: [ source ]
      )

      assert merger.merge!
    end

    assert_equal target.id, transaction.reload.category_id
    assert_equal target.id, source_child.reload.parent_id
    assert_equal 20.to_d, target_budget_category.reload.budgeted_spending
    assert_not BudgetCategory.exists?(source_budget_category.id)
    assert_not Category.exists?(source.id)
  end

  private
    def create_category(family, name, parent: nil)
      family.categories.create!(
        name: name,
        color: "#000000",
        lucide_icon: "shapes",
        parent: parent
      )
    end

    def create_transaction_for(family, category)
      transaction = Transaction.create!(category: category)
      Entry.create!(
        account: account_for(family),
        entryable: transaction,
        name: "#{category.name} transaction",
        date: Date.current,
        amount: 10,
        currency: family.currency || "USD"
      )

      transaction
    end

    def account_for(family)
      family.accounts.first || family.accounts.create!(
        accountable: Depository.create!(subtype: "checking"),
        name: "#{family.name} Checking",
        balance: 0,
        currency: family.currency || "USD"
      )
    end

    def create_budget(family, start_date)
      family.budgets.create!(
        start_date: start_date,
        end_date: start_date.end_of_month,
        currency: family.currency || "USD"
      )
    end

    def create_budget_category(budget, category, budgeted_spending)
      budget.budget_categories.create!(
        category: category,
        budgeted_spending: budgeted_spending,
        currency: budget.currency
      )
    end
end
