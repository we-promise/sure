require "test_helper"

class Assistant::Function::CreateGoalTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::CreateGoal.new(@user)
  end

  test "publishes one stable-id funding contract without legacy selectors" do
    schema = @fn.params_schema

    assert_equal %w[name target_amount funding_accounts], schema[:required]
    assert schema[:properties].key?(:funding_accounts)
    refute schema[:properties].key?(:linked_account_names)
    refute schema[:properties].key?(:linked_account_ids)
    refute schema[:properties].key?(:earmarks)

    item = schema.dig(:properties, :funding_accounts, :items)
    assert_equal %w[account_id allocation], item[:required]
    assert_equal %w[whole_account fixed_amount], item.dig(:properties, :allocation, :properties, :mode, :enum)
  end

  test "creates a whole-account goal from a stable account id" do
    account = create_account(name: "Vacation Savings", type: Depository)

    result = @fn.call(goal_params(account, mode: "whole_account"))

    assert result[:success]
    link = Goal.find(result[:goal_id]).goal_accounts.first
    assert_equal account.id, link.account_id
    assert_nil link.allocated_amount
  end

  test "creates a fixed allocation on an account already claimed in full" do
    account = create_account(name: "Claimed Pot", type: Depository, balance: 5_000)
    @family.goals.create!(name: "Precaution", target_amount: 5_000, currency: "USD") do |goal|
      goal.goal_accounts.build(account: account)
    end

    result = @fn.call(goal_params(account, mode: "fixed_amount", amount: 1_000))

    assert result[:success]
    assert_equal 1_000, Goal.find(result[:goal_id]).goal_accounts.first.allocated_amount.to_d
  end

  test "rejects a second whole-account claim with actionable account metadata" do
    account = create_account(name: "Claimed Pot", type: Depository, balance: 5_000)
    @family.goals.create!(name: "Precaution", target_amount: 5_000, currency: "USD") do |goal|
      goal.goal_accounts.build(account: account)
    end

    result = @fn.call(goal_params(account, mode: "whole_account"))

    assert_equal false, result[:success]
    assert_equal "account_claimed_in_full", result[:error]
    listed = result[:available_accounts].find { |item| item[:id] == account.id }
    assert_equal "whole_account_claimed", listed.dig(:goal_funding, :status)
    assert listed.dig(:goal_funding, :free_to_earmark).present?
  end

  test "allows accessible investment funding" do
    account = create_account(name: "Brokerage", type: Investment)

    result = @fn.call(goal_params(account, mode: "fixed_amount", amount: 250))

    assert result[:success]
    assert_equal account.id, Goal.find(result[:goal_id]).goal_accounts.first.account_id
  end

  test "rejects missing and inaccessible accounts" do
    no_funding = @fn.call("name" => "X", "target_amount" => 100, "funding_accounts" => [])
    assert_equal "no_funding_accounts", no_funding[:error]

    inaccessible = create_account(name: "Hidden", type: Depository)
    inaccessible.update!(status: "disabled")

    hidden = @fn.call(goal_params(inaccessible, mode: "whole_account"))
    assert_equal "unknown_accounts", hidden[:error]
    assert_equal [ inaccessible.id.to_s ], hidden[:unknown_ids]

    unknown = @fn.call("name" => "X", "target_amount" => 100, "funding_accounts" => [ funding_item(SecureRandom.uuid) ])
    assert_equal "unknown_accounts", unknown[:error]
  end

  test "supports mixed-currency funding in the family currency" do
    usd = create_account(name: "USD", type: Depository, currency: "USD")
    eur = create_account(name: "EUR", type: Depository, currency: "EUR")

    result = @fn.call(
      "name" => "Mixed",
      "target_amount" => 100,
      "funding_accounts" => [
        funding_item(usd.id, mode: "whole_account"),
        funding_item(eur.id, mode: "fixed_amount", amount: 50)
      ]
    )

    assert result[:success]
    assert_equal @family.primary_currency_code, result[:currency]
    links = Goal.find(result[:goal_id]).goal_accounts.index_by(&:account_id)
    assert_nil links.fetch(usd.id).allocated_amount
    assert_equal 50, links.fetch(eur.id).allocated_amount.to_d
  end

  test "rejects malformed allocation strategies" do
    account = create_account(name: "Savings", type: Depository)

    missing_amount = @fn.call(goal_params(account, mode: "fixed_amount"))
    invalid_mode = @fn.call(goal_params(account, mode: "percentage", amount: 50))
    amount_on_whole = @fn.call(goal_params(account, mode: "whole_account", amount: 50))

    assert_equal "invalid_allocation", missing_amount[:error]
    assert_equal "invalid_allocation", invalid_mode[:error]
    assert_equal "invalid_allocation", amount_on_whole[:error]
  end

  test "returns soft validation errors for missing name and invalid target" do
    account = create_account(name: "Savings", type: Depository)

    missing_name = @fn.call(goal_params(account, mode: "whole_account").except("name"))
    invalid_target = @fn.call(goal_params(account, mode: "whole_account").merge("target_amount" => 0))

    assert_equal "name_required", missing_name[:error]
    assert_equal "target_amount_invalid", invalid_target[:error]
  end

  test "allows fixed allocations above current balance for pro-rata goal funding" do
    account = create_account(name: "Shared savings", type: Depository, balance: 1_000)
    @family.goals.create!(name: "First", target_amount: 900, currency: "USD") do |goal|
      goal.goal_accounts.build(account: account, allocated_amount: 700)
    end

    result = @fn.call(goal_params(account, mode: "fixed_amount", amount: 400))

    assert result[:success]
    assert_equal 400, Goal.find(result[:goal_id]).goal_accounts.first.allocated_amount.to_d
  end

  private
    def goal_params(account, mode:, amount: nil)
      {
        "name" => "Vacation",
        "target_amount" => 2_000,
        "target_date" => 6.months.from_now.to_date.iso8601,
        "funding_accounts" => [ funding_item(account.id, mode:, amount:) ]
      }
    end

    def funding_item(account_id, mode: "whole_account", amount: nil)
      allocation = { "mode" => mode }
      allocation["amount"] = amount unless amount.nil?
      { "account_id" => account_id, "allocation" => allocation }
    end

    def create_account(name:, type:, balance: 1_000, currency: "USD")
      @family.accounts.create!(
        owner: @user,
        name:,
        accountable: type.new,
        balance:,
        currency:
      )
    end
end
