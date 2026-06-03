require "test_helper"

class Assistant::Function::CreateGoalTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @depository = accounts(:depository)
    @fn = Assistant::Function::CreateGoal.new(@user)
  end

  test "to_definition returns valid JSON shape" do
    definition = @fn.to_definition
    assert_equal "create_goal", definition[:name]
    assert_kind_of String, definition[:description]
    assert_equal "object", definition[:params_schema][:type]
    assert_includes definition[:params_schema][:required], "name"
    assert_includes definition[:params_schema][:required], "target_amount"
    assert_includes definition[:params_schema][:required], "linked_account_names"
  end

  test "creates a goal with linked accounts" do
    assert_difference -> { Goal.count } => 1,
                      -> { GoalAccount.count } => 1 do
      result = @fn.call(
        "name" => "Vacation",
        "target_amount" => 1500,
        "target_date" => 3.months.from_now.to_date.iso8601,
        "linked_account_names" => [ @depository.name ]
      )

      assert result[:success]
      assert_match(/Vacation/, result[:message])
      assert result[:url].present?
      assert_equal "USD", result[:currency]
    end
  end

  test "soft error when name is missing" do
    result = @fn.call("target_amount" => 100, "linked_account_names" => [ @depository.name ])
    assert_equal false, result[:success]
    assert_equal "name_required", result[:error]
  end

  test "soft error when target_amount is zero" do
    result = @fn.call("name" => "X", "target_amount" => 0, "linked_account_names" => [ @depository.name ])
    assert_equal false, result[:success]
    assert_equal "target_amount_invalid", result[:error]
  end

  test "soft error when no linked accounts" do
    result = @fn.call("name" => "X", "target_amount" => 100, "linked_account_names" => [])
    assert_equal false, result[:success]
    assert_equal "no_linked_accounts", result[:error]
    assert_kind_of Array, result[:available_accounts]
    assert(result[:available_accounts].all? { |a| a.is_a?(Hash) && a.key?(:name) })
  end

  test "soft error when account name doesn't match" do
    result = @fn.call("name" => "X", "target_amount" => 100, "linked_account_names" => [ "Nonexistent Account" ])
    assert_equal false, result[:success]
    assert_equal "unknown_accounts", result[:error]
    assert_includes result[:unknown_names], "Nonexistent Account"
  end

  test "soft error when currencies differ across linked accounts" do
    eur = Account.create!(family: @family, accountable: Depository.new, name: "EUR Account", currency: "EUR", balance: 100)
    result = @fn.call(
      "name" => "Mixed",
      "target_amount" => 100,
      "linked_account_names" => [ @depository.name, eur.name ]
    )
    assert_equal false, result[:success]
    assert_equal "currency_mismatch", result[:error]
  end

  test "scopes to the user's family" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    Account.create!(family: other_family, accountable: Depository.new, name: "Foreign Checking", currency: "USD", balance: 100)

    result = @fn.call(
      "name" => "X",
      "target_amount" => 100,
      "linked_account_names" => [ "Foreign Checking" ]
    )
    assert_equal false, result[:success]
    assert_equal "unknown_accounts", result[:error]
  end
end
