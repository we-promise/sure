# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261106150000_move_categorization_comparisons_to_ai_comparisons")

# CategorizationComparison rows become categorize comparisons in ai_comparisons.
# The test schema already has the new table, so each test runs `down` to get the old one back.
class MoveCategorizationComparisonsToAiComparisonsMigrationTest < ActiveSupport::TestCase
  setup do
    @migration = MoveCategorizationComparisonsToAiComparisons.new
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "Migration test", balance: 0, currency: "USD", accountable: Depository.new)
    @transaction = @account.entries.create!(date: Date.current, name: "Blue Bottle", amount: 5, currency: "USD", entryable: Transaction.new).entryable
    @coffee = @family.categories.create!(name: "Coffee Migrated")
    migrate(:down)
  end

  teardown { Ai::Comparison.reset_column_information }

  def migrate(direction) = ActiveRecord::Migration.suppress_messages { @migration.public_send(direction) }

  def old_row(**values)
    defaults = { agreed: false, applied_provider: "openai", applied_category_name: @coffee.name, shadow_provider: "jev",
                 shadow_category_name: "Deleted Category", shadow_confidence: 0.52, shadow_probabilities: { "Deleted Category" => 0.52 }.to_json,
                 family_id: @family.id, transaction_id: @transaction.id }
    row = defaults.merge(values)
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "INSERT INTO categorization_comparisons (#{row.keys.join(", ")}, created_at, updated_at) " \
      "VALUES (#{([ "?" ] * row.size).join(", ")}, '2026-10-01', '2026-10-01')", *row.values
    ]))
  end

  test "copies each comparison as a categorize comparison, names mapped to the family's ids" do
    old_row

    migrate(:up)

    comparison = Ai::Comparison.sole
    assert_equal "categorize", comparison.feature
    assert_equal @family, comparison.family
    assert_equal @transaction, comparison.subject
    assert_equal({ "endpoint" => "openai" }, comparison.primary_route)
    assert_equal({ "endpoint" => "jev" }, comparison.shadow_route)
    assert_equal @coffee.id, comparison.primary_value
    assert_nil comparison.shadow_value, "no category has that name any more"
    assert_in_delta 0.52, comparison.shadow_confidence, 0.0001
    assert_not comparison.agreed
    assert_equal({ "primary_category_name" => @coffee.name, "shadow_category_name" => "Deleted Category",
                   "shadow_probabilities" => { "Deleted Category" => 0.52 } }, comparison.metadata)
    assert_equal Date.new(2026, 10, 1), comparison.created_at.to_date
    assert_equal [ @coffee.name, "Deleted Category" ], %i[primary shadow].map { comparison.category_name(_1, Ai::Comparison.category_names([ comparison ], @family)) }
    assert_not ActiveRecord::Base.connection.table_exists?(:categorization_comparisons)
  end

  test "a comparison whose transaction is gone keeps no subject, and a shared abstention stays agreed" do
    old_row(transaction_id: nil, applied_category_name: nil, shadow_category_name: nil, agreed: true, shadow_probabilities: "{}")

    migrate(:up)

    comparison = Ai::Comparison.sole
    assert_nil comparison.subject_type
    assert comparison.agreed
    assert_equal({}, comparison.metadata)
  end

  test "down copies categorize comparisons back" do
    old_row
    migrate(:up)

    migrate(:down)

    row = ActiveRecord::Base.connection.select_one("SELECT * FROM categorization_comparisons")
    assert_equal [ "openai", @coffee.name, "jev", "Deleted Category" ],
                 row.values_at("applied_provider", "applied_category_name", "shadow_provider", "shadow_category_name")
    assert_equal @transaction.id, row["transaction_id"]
    migrate(:up)
  end
end
