require "test_helper"

class Assistant::Function::GetPurchasesTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @fn = Assistant::Function::GetPurchases.new(@user)
    @awaiting = purchases(:allegro_awaiting)
    @matched = purchases(:allegro_matched)
  end

  test "definition" do
    definition = @fn.to_definition

    assert_equal "get_purchases", definition[:name]
    assert_match(/bought/i, definition[:description])
  end

  test "finds a purchase by an item name with its items and transaction" do
    result = @fn.call({ "query" => "coffee" })

    assert_equal 1, result[:total_results]
    purchase = result[:purchases].first
    assert_equal @matched.id, purchase[:id]
    assert_equal [ { name: "Coffee beans", quantity: "1.0", amount: "10.0", category: "Food & Drink" } ], purchase[:items]
    assert_equal "Checking Account", purchase[:account_name]
    assert_equal @matched.transaction_id, purchase[:transaction_id]
  end

  test "a share removed between two calls hides the account from the second" do
    assert_equal "Checking Account", @fn.call({ "query" => "coffee" })[:purchases].first[:account_name]

    Account.stubs(:accessible_by).with(@user).returns(Account.none)

    purchase = @fn.call({ "query" => "coffee" })[:purchases].first
    assert_nil purchase[:account_name]
    assert_nil purchase[:transaction_id]
  end

  test "filters by date range and status" do
    result = @fn.call({ "start_date" => @awaiting.ordered_on.iso8601, "end_date" => @awaiting.ordered_on.iso8601 })
    assert_equal [ @awaiting.id ], result[:purchases].map { _1[:id] }

    result = @fn.call({ "status" => "matched" })
    assert_equal [ @matched.id ], result[:purchases].map { _1[:id] }
  end

  test "filters by item category" do
    result = @fn.call({ "category" => "food & drink" })

    assert_equal [ @matched.id ], result[:purchases].map { _1[:id] }
  end

  test "another member doesn't see an unlinked purchase" do
    result = Assistant::Function::GetPurchases.new(users(:family_member)).call({})

    refute_includes result[:purchases].map { _1[:id] }, @awaiting.id
    assert_includes result[:purchases].map { _1[:id] }, @matched.id
  end

  test "limit is capped" do
    result = @fn.call({ "limit" => 500 })

    assert_operator result[:purchases].size, :<=, Assistant::Function::GetPurchases::MAX_LIMIT
    assert_equal 50, Assistant::Function::GetPurchases::MAX_LIMIT
  end

  test "is offered only to users with preview features" do
    refute_includes Assistant.function_classes(@user), Assistant::Function::GetPurchases

    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    assert_includes Assistant.function_classes(@user), Assistant::Function::GetPurchases
  end
end
