# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260808120000_add_unique_index_on_categories_family_id_and_name")

class AddUniqueIndexOnCategoriesFamilyIdAndNameTest < ActiveSupport::TestCase
  INDEX_NAME = AddUniqueIndexOnCategoriesFamilyIdAndName::INDEX_NAME

  setup do
    @migration = AddUniqueIndexOnCategoriesFamilyIdAndName.new
    @family = families(:dylan_family)
    @budget = budgets(:one)
  end

  test "sums colliding budgeted_spending into keeper before deleting duplicate budget categories" do
    drop_unique_index_if_present!

    keeper = create_category("Dedupe Budget Keeper")
    duplicate = create_duplicate_category!(keeper.name)

    keeper_amount = 125.50
    duplicate_amount = 40.25
    expected_total = keeper_amount + duplicate_amount

    keeper_bc = @budget.budget_categories.create!(
      category: keeper,
      budgeted_spending: keeper_amount,
      currency: @budget.currency
    )
    @budget.budget_categories.create!(
      category: duplicate,
      budgeted_spending: duplicate_amount,
      currency: @budget.currency
    )

    assert_difference -> { Category.where(id: duplicate.id).count }, -1 do
      @migration.up
    end

    assert_not Category.exists?(duplicate.id)
    assert_equal expected_total, keeper_bc.reload.budgeted_spending
    assert_equal 1, @budget.budget_categories.where(category_id: keeper.id).count
    assert index_present?, "unique index should be restored after migration"
  ensure
    ensure_unique_index!
  end

  test "reassigns non-colliding budget_categories to the keeper without changing amount" do
    drop_unique_index_if_present!

    keeper = create_category("Dedupe Budget Reassign Keeper")
    duplicate = create_duplicate_category!(keeper.name)
    amount = 75

    duplicate_bc = @budget.budget_categories.create!(
      category: duplicate,
      budgeted_spending: amount,
      currency: @budget.currency
    )

    @migration.up

    assert_not Category.exists?(duplicate.id)
    assert_equal keeper.id, duplicate_bc.reload.category_id
    assert_equal amount, duplicate_bc.budgeted_spending
  ensure
    ensure_unique_index!
  end

  test "collapses multiple duplicate budget_categories for the same budget when keeper has none" do
    drop_unique_index_if_present!

    keeper = create_category("Dedupe Multi Dup Budget Keeper")
    duplicate_a = create_duplicate_category!(keeper.name)
    duplicate_b = create_duplicate_category!(keeper.name)

    amount_a = 30
    amount_b = 45
    expected_total = amount_a + amount_b

    @budget.budget_categories.create!(
      category: duplicate_a,
      budgeted_spending: amount_a,
      currency: @budget.currency
    )
    @budget.budget_categories.create!(
      category: duplicate_b,
      budgeted_spending: amount_b,
      currency: @budget.currency
    )

    assert_difference -> { Category.where(id: [ duplicate_a.id, duplicate_b.id ]).count }, -2 do
      @migration.up
    end

    assert_not Category.exists?(duplicate_a.id)
    assert_not Category.exists?(duplicate_b.id)

    keeper_budget_categories = @budget.budget_categories.where(category_id: keeper.id)
    assert_equal 1, keeper_budget_categories.count
    assert_equal expected_total, keeper_budget_categories.first.budgeted_spending
  ensure
    ensure_unique_index!
  end

  test "remaps import_source_mappings Category targets to the keeper and leaves other targets alone" do
    drop_unique_index_if_present!

    keeper = create_category("Dedupe Import Source Keeper")
    duplicate = create_duplicate_category!(keeper.name)
    account = accounts(:depository)
    session = @family.import_sessions.create!(client_session_id: "dedupe-category-mapping", expected_chunks: 1)

    category_mapping = ImportSourceMapping.create!(
      family: @family,
      import_session: session,
      source_type: "Category",
      source_id: "ext-category-1",
      target_type: "Category",
      target_id: duplicate.id
    )
    account_mapping = ImportSourceMapping.create!(
      family: @family,
      import_session: session,
      source_type: "Account",
      source_id: "ext-account-1",
      target_type: "Account",
      target_id: account.id
    )

    @migration.up

    assert_not Category.exists?(duplicate.id)
    assert_equal keeper.id, category_mapping.reload.target_id
    assert_equal "Category", category_mapping.target_type
    assert_equal account.id, account_mapping.reload.target_id
    assert_equal "Account", account_mapping.target_type
  ensure
    ensure_unique_index!
  end

  private
    def create_category(name)
      @family.categories.create!(
        name: name,
        color: "#123456",
        lucide_icon: "shapes"
      )
    end

    def create_duplicate_category!(name)
      duplicate = Category.new(
        name: name,
        color: "#654321",
        lucide_icon: "shapes",
        family: @family
      )
      duplicate.save!(validate: false)
      duplicate
    end

    def drop_unique_index_if_present!
      return unless index_present?

      ActiveRecord::Base.connection.remove_index :categories, name: INDEX_NAME
    end

    def ensure_unique_index!
      return if index_present?

      ActiveRecord::Base.connection.add_index :categories, [ :family_id, :name ], unique: true, name: INDEX_NAME
    end

    def index_present?
      ActiveRecord::Base.connection.index_exists?(:categories, [ :family_id, :name ], unique: true, name: INDEX_NAME)
    end
end
