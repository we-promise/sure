require "test_helper"

class AkahuAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @akahu_item = AkahuItem.create!(
      family: @family,
      name: "Test Akahu",
      app_token: "app-token",
      user_token: "user-token"
    )
    @akahu_account = AkahuAccount.create!(
      akahu_item: @akahu_item,
      name: "Test Invest - Portfolio",
      account_id: "investment_123",
      currency: "NZD",
      current_balance: 12_345.67
    )
    @account = Account.create!(
      family: @family,
      name: "Portfolio",
      accountable: Investment.new,
      balance: 0,
      cash_balance: 999,
      currency: "NZD"
    )

    AccountProvider.create!(account: @account, provider: @akahu_account)
  end

  test "updates investment account balance without treating portfolio value as cash" do
    AkahuAccount::Processor.new(@akahu_account).process

    @account.reload
    assert_equal BigDecimal("12345.67"), @account.balance
    assert_equal BigDecimal("0"), @account.cash_balance
    assert_equal "NZD", @account.currency
  end
end
