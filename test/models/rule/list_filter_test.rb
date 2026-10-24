require "test_helper"

class Rule::ListFilterTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", balance: 0, currency: "USD", accountable: Depository.new)
    @category = @family.categories.create!(name: "Groceries")
    @merchant = @family.merchants.create!(name: "Corner Shop", type: "FamilyMerchant")
    @rule = @family.rules.create!(
      name: "Weekly shop",
      resource_type: "transaction",
      conditions: [
        Rule::Condition.new(condition_type: "transaction_account", operator: "=", value: @account.id),
        Rule::Condition.new(condition_type: "compound", operator: "or", sub_conditions: [
          Rule::Condition.new(condition_type: "transaction_merchant", operator: "=", value: @merchant.id),
          Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "market")
        ])
      ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @category.id) ]
    )
    Current.stubs(:user).returns(users(:empty))
    @filter = Rule::ListFilter.new(@family.rules.includes(:actions, conditions: :sub_conditions))
  end

  test "search text names the values of conditions and actions, including those in a condition group" do
    text = @filter.search_text(@rule)

    [ "Weekly shop", "Checking", "Corner Shop", "market", "Groceries" ].each do |part|
      assert_includes text, part
    end
  end

  test "lists the types and accounts a rule uses" do
    assert_equal [ "set_transaction_category" ], @filter.action_types(@rule)
    assert_equal %w[transaction_account transaction_merchant transaction_name], @filter.condition_types(@rule).sort
    assert_equal [ @account.id ], @filter.account_ids(@rule)
  end

  test "offers only the types and accounts the rules use" do
    assert_equal [ "set_transaction_category" ], @filter.action_type_options.map(&:last)
    assert_not_includes @filter.condition_type_options.map(&:last), "transaction_amount"
    assert_equal [ [ "Checking", @account.id ] ], @filter.account_options
  end

  test "search text includes the text of a free-text action" do
    rule = @family.rules.create!(name: "Rename", resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "set_transaction_name", value: "Weekly groceries") ])

    assert_includes Rule::ListFilter.new([ rule ]).search_text(rule), "Weekly groceries"
  end

  test "search text shows a split's summary, not its stored JSON" do
    rule = @family.rules.create!(name: "Share rent", resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "split_transaction", value: {
        splits: [ { type: "percentage", name: "Mine", share: "50" }, { type: "percentage", name: "Theirs", share: "50" } ]
      }.to_json) ])

    text = Rule::ListFilter.new([ rule ]).search_text(rule)

    assert_includes text, I18n.t("rules.actions.split.summary", count: 2)
    assert_not_includes text, "percentage"
  end
end
