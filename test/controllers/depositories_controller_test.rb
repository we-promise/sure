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

  test "persists fixed return settings" do
    patch depository_path(@account), params: {
      account: {
        accountable_attributes: {
          id: @account.accountable_id,
          fixed_return_rate: 3.25,
          fixed_return_frequency: "monthly",
          fixed_return_start_date: "2026-01-01"
        }
      }
    }

    depository = @account.reload.depository

    assert_equal 3.25, depository.fixed_return_rate
    assert_equal "monthly", depository.fixed_return_frequency
    assert_equal Date.new(2026, 1, 1), depository.fixed_return_start_date
    assert depository.fixed_return?
  end

  test "rejects an unknown fixed return frequency" do
    depository = @account.depository
    depository.fixed_return_frequency = "hourly"

    assert_not depository.valid?
    assert_includes depository.errors[:fixed_return_frequency], "is not included in the list"
  end

  test "edit form renders the fixed return fields" do
    get edit_account_url(@account)

    assert_response :success
    assert_select "input[name='account[accountable_attributes][fixed_return_rate]']", 1
    assert_select "select[name='account[accountable_attributes][fixed_return_frequency]']", 1
  end

  test "edit form renders category matcher toggle only for accounts that support it" do
    get edit_account_url(accounts(:connected))
    assert_response :success
    assert_select "input[type=checkbox][name='account[enable_category_matcher]']", 1

    get edit_account_url(accounts(:depository))
    assert_response :success
    assert_select "input[name='account[enable_category_matcher]']", 0
  end
end
