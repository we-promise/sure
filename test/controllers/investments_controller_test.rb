require "test_helper"

class InvestmentsControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:investment)
  end

  test "changing the method starts one sync of the account" do
    assert @account.cost_basis_average?
    Account.any_instance.expects(:sync_later).once

    patch investment_path(@account), params: { account: { cost_basis_method: "fifo" } }

    assert_redirected_to account_path(@account)
    assert @account.reload.cost_basis_fifo?
  end

  test "resubmitting the same method starts no sync" do
    Account.any_instance.expects(:sync_later).never

    patch investment_path(@account), params: { account: { name: "Renamed", cost_basis_method: "average" } }

    assert_redirected_to account_path(@account)
    assert_equal "Renamed", @account.reload.name
  end

  test "an unknown method is rejected" do
    Account.any_instance.expects(:sync_later).never

    patch investment_path(@account), params: { account: { cost_basis_method: "lifo" } }

    assert_response :unprocessable_entity
    assert @account.reload.cost_basis_average?
  end

  test "the method select is on the form of an account that supports trades, and only there" do
    get edit_investment_path(@account)
    assert_select "select[name='account[cost_basis_method]'] option", count: 2

    get edit_depository_path(accounts(:depository))
    assert_response :success
    assert_select "select[name='account[cost_basis_method]']", count: 0
  end

  test "a new account starts on average whatever the form submits" do
    assert_difference "Account.count", 1 do
      post investments_path, params: {
        account: { name: "New brokerage", currency: "USD", balance: 1000, accountable_type: "Investment", cost_basis_method: "fifo" }
      }
    end

    assert Account.order(:created_at).last.cost_basis_average?
  end

  test "an account that does not support trades ignores a submitted method" do
    depository = accounts(:depository)
    Account.any_instance.expects(:sync_later).never

    patch depository_path(depository), params: { account: { cost_basis_method: "fifo" } }

    assert depository.reload.cost_basis_average?
  end
end
