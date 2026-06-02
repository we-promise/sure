require "test_helper"

class DepositoriesControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "create redirects to stored return_to" do
    Family.any_instance.stubs(:get_link_token).returns("test-link-token")

    get new_depository_path(return_to: accounts_path)

    assert_difference -> { Account.count } => 1 do
      post depositories_path, params: {
        account: {
          name: "New Checking",
          balance: 1000,
          currency: "USD",
          accountable_type: "Depository",
          accountable_attributes: {
            subtype: "checking"
          }
        }
      }
    end

    assert_redirected_to accounts_path
  end

  test "create falls back to created account without return_to" do
    assert_difference -> { Account.count } => 1 do
      post depositories_path, params: {
        account: {
          name: "New Savings",
          balance: 2500,
          currency: "USD",
          accountable_type: "Depository",
          accountable_attributes: {
            subtype: "savings"
          }
        }
      }
    end

    created_account = Account.find_by!(name: "New Savings")
    assert_redirected_to account_path(created_account)
  end

  test "create falls back to created account with unsafe account return_to" do
    assert_difference -> { Account.count } => 1 do
      post depositories_path, params: {
        account: {
          name: "New Certificate",
          balance: 4000,
          currency: "USD",
          accountable_type: "Depository",
          return_to: "//evil.example/accounts",
          accountable_attributes: {
            subtype: "cd"
          }
        }
      }
    end

    created_account = Account.find_by!(name: "New Certificate")
    assert_redirected_to account_path(created_account)
  end

  test "create uses stored safe return_to when account return_to is unsafe" do
    get new_depository_path(return_to: accounts_path)

    assert_difference -> { Account.count } => 1 do
      post depositories_path, params: {
        account: {
          name: "New Brokerage",
          balance: 5000,
          currency: "USD",
          accountable_type: "Depository",
          return_to: "//evil.example/accounts",
          accountable_attributes: {
            subtype: "checking"
          }
        }
      }
    end

    assert_redirected_to accounts_path
  end

  test "create uses stored safe return_to when account return_to contains path traversal" do
    get new_depository_path(return_to: accounts_path)

    assert_difference -> { Account.count } => 1 do
      post depositories_path, params: {
        account: {
          name: "New Treasury",
          balance: 7000,
          currency: "USD",
          accountable_type: "Depository",
          return_to: "/foo/../../../etc/passwd",
          accountable_attributes: {
            subtype: "savings"
          }
        }
      }
    end

    assert_redirected_to accounts_path
  end

  test "unsafe request return_to does not clear stored safe return_to" do
    get new_depository_path(return_to: accounts_path)
    get new_depository_path(return_to: "//evil.example/accounts")

    assert_difference -> { Account.count } => 1 do
      post depositories_path, params: {
        account: {
          name: "New Money Market",
          balance: 3000,
          currency: "USD",
          accountable_type: "Depository",
          accountable_attributes: {
            subtype: "money_market"
          }
        }
      }
    end

    assert_redirected_to accounts_path
  end
end
