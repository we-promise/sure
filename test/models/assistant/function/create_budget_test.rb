require "test_helper"

class Assistant::Function::CreateBudgetTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @function = Assistant::Function::CreateBudget.new(@user)
  end

  test "has correct name" do
    assert_equal "create_budget", @function.name
  end

  test "requires a name" do
    result = @function.call({ "name" => "  " })

    assert_equal false, result[:success]
    assert_equal "name_required", result[:error]
  end

  test "creates an unscoped budget from a name" do
    assert_difference "BudgetPlan.count", 1 do
      result = @function.call({ "name" => "Test" })

      assert result[:success]
      assert_equal "test", result[:slug]
      assert_equal "all_accounts", result[:accounts]
    end
  end

  test "creates a scoped budget from account names and ids" do
    depository = accounts(:depository)
    credit_card = accounts(:credit_card)

    result = @function.call({ "name" => "Scoped", "accounts" => [ depository.name, credit_card.id ] })

    assert result[:success]
    plan = @family.budget_plans.find_by!(slug: "scoped")
    assert_equal [ credit_card.id, depository.id ].sort, plan.scoped_account_ids.sort
  end

  test "reports unknown accounts with the available list" do
    result = @function.call({ "name" => "Bad", "accounts" => [ "No Such Account" ] })

    assert_equal false, result[:success]
    assert_equal "unknown_accounts", result[:error]
    assert_includes result[:unknown_accounts], "No Such Account"
    assert result[:available_accounts].any?
    assert_not @family.budget_plans.exists?(slug: "bad")
  end

  test "reports ambiguous account names" do
    account = accounts(:depository)
    @family.accounts.create!(
      name: account.name,
      accountable: Depository.new,
      status: "active",
      currency: "USD",
      balance: 0
    )

    result = @function.call({ "name" => "Ambiguous", "accounts" => [ account.name ] })

    assert_equal false, result[:success]
    assert_equal "ambiguous_accounts", result[:error]
    assert_includes result[:ambiguous_names], account.name
  end

  test "rejects foreign account ids as unknown" do
    foreign_account = Account.create!(
      family: families(:empty),
      accountable: Depository.new,
      name: "Foreign",
      status: "active",
      currency: "USD",
      balance: 0
    )

    result = @function.call({ "name" => "Sneaky", "accounts" => [ foreign_account.id ] })

    assert_equal false, result[:success]
    assert_equal "unknown_accounts", result[:error]
  end

  test "duplicate names succeed with a uniquified slug" do
    @family.budget_plans.create!(name: "Dup")

    result = @function.call({ "name" => "Dup" })

    assert result[:success]
    assert_equal "dup-2", result[:slug]
  end
  test "cannot scope a budget to an account that isn't shared with the caller" do
    private_account = users(:family_admin).family.accounts.create!(
      accountable: Depository.new,
      name: "Admin Private",
      status: "active",
      currency: "USD",
      balance: 0,
      owner: users(:family_admin)
    )
    function = Assistant::Function::CreateBudget.new(users(:family_member))

    result = function.call("name" => "Sneaky", "accounts" => [ private_account.name ])

    assert_equal false, result[:success]
    assert_equal "unknown_accounts", result[:error]
  end
end
