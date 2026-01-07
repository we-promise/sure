require "test_helper"

class DepositoriesControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "creates depository account with subtype" do
    assert_difference "Account.count", 1 do
      assert_difference "Depository.count", 1 do
        post depositories_url, params: {
          account: {
            name: "Test Checking",
            balance: 5000,
            currency: "USD",
            accountable_type: "Depository",
            accountable_attributes: {
              subtype: "checking"
            }
          }
        }
      end
    end

    created_account = Account.order(:created_at).last
    assert_redirected_to account_url(created_account)
    assert_equal "checking", created_account.accountable.subtype
    assert_equal "checking", created_account.subtype # via delegation
  end

  test "updates depository account subtype" do
    # Ensure account starts with a subtype
    @account.accountable.update!(subtype: "checking")
    @account.reload

    patch account_url(@account), params: {
      account: {
        name: @account.name,
        accountable_attributes: {
          id: @account.accountable.id,
          subtype: "savings"
        }
      }
    }

    assert_redirected_to account_url(@account)
    @account.reload
    assert_equal "savings", @account.accountable.subtype
    assert_equal "savings", @account.subtype # via delegation
  end
end
