require "test_helper"

class DepositoriesControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "create falls back to the stored return_to when no form param is present" do
    get new_account_path(return_to: transactions_path) # StoreLocation captures it into the session

    assert_difference -> { Account.count } => 1 do
      post depositories_path, params: {
        account: { name: "Return To Checking", currency: "USD", balance: 100, accountable_type: "Depository" }
      }
    end

    assert_redirected_to transactions_path
  end

  test "create prefers the form return_to over the session value" do
    get new_account_path(return_to: transactions_path) # session return_to

    post depositories_path, params: {
      account: { name: "Form RT Checking", currency: "USD", balance: 100, accountable_type: "Depository", return_to: budgets_path }
    }

    assert_redirected_to budgets_path
  end

  test "create ignores an external return_to (open-redirect guard)" do
    post depositories_path, params: {
      account: { name: "Evil RT Checking", currency: "USD", balance: 100, accountable_type: "Depository", return_to: "https://evil.example/phish" }
    }

    created = Account.order(:created_at).last
    assert_redirected_to account_path(created) # not the external URL
  end

  test "update persists enable_category_matcher through the shared update action" do
    linked_account = accounts(:connected)
    assert linked_account.enable_category_matcher?

    patch depository_path(linked_account), params: {
      account: { enable_category_matcher: "0" }
    }

    refute linked_account.reload.enable_category_matcher?

    patch depository_path(linked_account), params: {
      account: { enable_category_matcher: "1" }
    }

    assert linked_account.reload.enable_category_matcher?
  end

  test "edit form renders category matcher toggle only for accounts that support it" do
    get edit_account_url(accounts(:connected))
    assert_response :success
    assert_select "input[type=checkbox][name='account[enable_category_matcher]']", 1

    get edit_account_url(accounts(:depository))
    assert_response :success
    assert_select "input[name='account[enable_category_matcher]']", 0
  end

  test "persists the overdraft terms this controller previously dropped" do
    patch depository_path(@account), params: {
      account: {
        name: @account.name,
        balance: @account.balance,
        currency: @account.currency,
        accountable_type: "Depository",
        accountable_attributes: {
          id: @account.accountable_id,
          overdraft_limit: 400,
          overdraft_interest_rate: 16.5,
          intervention_fee_amount: 8,
          intervention_fee_threshold: 20,
          intervention_fee_monthly_cap: 80,
          intervention_fee_monthly_count_cap: 10
        }
      }
    }

    depository = @account.reload.depository

    assert_equal 400, depository.overdraft_limit.to_f
    assert_equal 16.5, depository.overdraft_interest_rate.to_f
    assert_equal 8, depository.intervention_fee_amount.to_f
    assert_equal 20, depository.intervention_fee_threshold.to_f
    assert_equal 80, depository.intervention_fee_monthly_cap.to_f
    assert_equal 10, depository.intervention_fee_monthly_count_cap
    assert_equal(-400, depository.overdraft_floor)
  end
end
