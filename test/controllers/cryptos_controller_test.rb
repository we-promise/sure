require "test_helper"

class CryptosControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:crypto)
    @family = @user.family
  end

  test "create persists subtype so account supports trades" do
    Family.any_instance.stubs(:get_link_token).returns("test-link-token")

    assert_difference "@family.accounts.count", 1 do
      post cryptos_path, params: {
        account: {
          name: "Crypto Exchange Account",
          balance: 0,
          currency: @family.currency,
          accountable_type: "Crypto",
          accountable_attributes: { subtype: "exchange", tax_treatment: "taxable" }
        }
      }
    end

    assert_response :redirect
    created = Account.find(URI(response.location).path.split("/").last)
    assert_redirected_to created
    assert_equal "exchange", created.accountable.subtype, "subtype must be persisted for trades API"
    assert created.supports_trades?, "exchange crypto account must support trades"
  end

  test "update persists subtype" do
    @account.accountable.update_column(:subtype, nil)
    assert_nil @account.reload.accountable.subtype
    refute @account.supports_trades?

    patch crypto_path(@account), params: {
      account: {
        name: @account.name,
        balance: @account.balance,
        currency: @account.currency,
        accountable_attributes: { id: @account.accountable_id, subtype: "exchange", tax_treatment: "taxable" }
      }
    }

    assert_redirected_to @account
    @account.reload
    assert_equal "exchange", @account.accountable.subtype
    assert @account.supports_trades?
  end

  test "a method sent with a switch from exchange to wallet is dropped and starts no sync" do
    @account.accountable.update!(subtype: "exchange")
    Account.any_instance.expects(:sync_later).never

    patch crypto_path(@account), params: { account: { subtype: "wallet", cost_basis_method: "fifo" } }

    @account.reload
    assert_equal "wallet", @account.accountable.subtype
    assert @account.cost_basis_average?
  end

  test "a method sent with a switch from wallet to exchange is kept and starts one sync" do
    @account.accountable.update!(subtype: "wallet")
    Account.any_instance.expects(:sync_later).once

    patch crypto_path(@account), params: { account: { subtype: "exchange", cost_basis_method: "fifo" } }

    @account.reload
    assert_equal "exchange", @account.accountable.subtype
    assert @account.cost_basis_fifo?
  end
end
