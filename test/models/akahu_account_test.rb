require "test_helper"

class AkahuAccountTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = AkahuItem.create!(
      family: @family,
      name: "Test Akahu",
      app_token: "app-token",
      user_token: "user-token"
    )
    @account = AkahuAccount.create!(
      akahu_item: @item,
      name: "Test Account",
      account_id: "acc_123",
      currency: "NZD"
    )
  end

  test "maps common Akahu account types to Sure accountable types" do
    @account.update!(account_type: "CHECKING")
    assert_equal "Depository", @account.suggested_account_type
    assert_equal "checking", @account.suggested_subtype

    @account.update!(account_type: "SAVINGS")
    assert_equal "Depository", @account.suggested_account_type
    assert_equal "savings", @account.suggested_subtype

    @account.update!(account_type: "TERMDEPOSIT")
    assert_equal "Depository", @account.suggested_account_type
    assert_equal "cd", @account.suggested_subtype

    @account.update!(account_type: "CREDITCARD")
    assert_equal "CreditCard", @account.suggested_account_type
    assert_equal "credit_card", @account.suggested_subtype
  end

  test "maps KIWISAVER and INVESTMENT to Investment" do
    @account.update!(account_type: "KIWISAVER")
    assert_equal "Investment", @account.suggested_account_type
    assert_equal "retirement", @account.suggested_subtype

    @account.update!(account_type: "INVESTMENT")
    assert_equal "Investment", @account.suggested_account_type
    assert_nil @account.suggested_subtype
  end

  test "returns skip when Akahu account type is unmapped" do
    @account.update!(account_type: "WALLET")
    assert_nil @account.suggested_account_type
    assert_nil @account.suggested_subtype
  end

  test "is case insensitive for mapping" do
    @account.update!(account_type: "savings")
    assert_equal "Depository", @account.suggested_account_type
    assert_equal "savings", @account.suggested_subtype
  end
end
