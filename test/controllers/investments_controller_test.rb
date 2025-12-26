require "test_helper"

class InvestmentsControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:investment)
  end

  test "creates investment account with subtype" do
    assert_difference "Account.count", 1 do
      assert_difference "Investment.count", 1 do
        post investments_url, params: {
          account: {
            name: "Test Brokerage",
            balance: 10000,
            currency: "USD",
            accountable_type: "Investment",
            accountable_attributes: {
              subtype: "brokerage"
            }
          }
        }
      end
    end

    assert_redirected_to account_url(Account.last)
    assert_equal "brokerage", Account.last.accountable.subtype
    assert_equal "brokerage", Account.last.subtype # via delegation
  end

  test "updates investment account subtype" do
    # Ensure account starts with no subtype
    @account.accountable.update!(subtype: nil)
    @account.reload

    patch account_url(@account), params: {
      account: {
        name: @account.name,
        accountable_attributes: {
          id: @account.accountable.id,
          subtype: "retirement"
        }
      }
    }

    assert_redirected_to account_url(@account)
    @account.reload
    assert_equal "retirement", @account.accountable.subtype
    assert_equal "retirement", @account.subtype # via delegation
  end
end
