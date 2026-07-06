require "test_helper"

class OpenBankingIoAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @item = OpenBankingIoItem.create!(
      family: @family,
      name: "Test open-banking.io",
      api_base_url: "https://api.example.com",
      api_key: "test-api-key",
      private_key: "test-private-key"
    )
  end

  def build_linked(accountable:, current_balance:)
    provider_account = OpenBankingIoAccount.create!(
      open_banking_io_item: @item,
      name: "Linked",
      account_id: "acc_#{SecureRandom.hex(4)}",
      currency: "EUR",
      current_balance: current_balance
    )
    account = Account.create!(
      family: @family,
      name: "Linked",
      accountable: accountable,
      balance: 0,
      currency: "EUR"
    )
    AccountProvider.create!(account: account, provider: provider_account)
    [ provider_account, account ]
  end

  test "depository balance flows straight through" do
    provider_account, account = build_linked(accountable: Depository.new, current_balance: BigDecimal("500.00"))
    OpenBankingIoAccount::Processor.new(provider_account).process
    account.reload
    assert_equal BigDecimal("500.00"), account.balance
    assert_equal BigDecimal("500.00"), account.cash_balance
  end

  test "credit card balance is stored as an absolute value" do
    provider_account, account = build_linked(accountable: CreditCard.new, current_balance: BigDecimal("-250.00"))
    OpenBankingIoAccount::Processor.new(provider_account).process
    account.reload
    assert_equal BigDecimal("250.00"), account.balance
  end

  test "loan balance is stored as an absolute value" do
    provider_account, account = build_linked(accountable: Loan.new, current_balance: BigDecimal("-9000.00"))
    OpenBankingIoAccount::Processor.new(provider_account).process
    account.reload
    assert_equal BigDecimal("9000.00"), account.balance
  end

  test "investment cash_balance is zeroed" do
    provider_account, account = build_linked(accountable: Investment.new, current_balance: BigDecimal("1000.00"))
    OpenBankingIoAccount::Processor.new(provider_account).process
    account.reload
    assert_equal BigDecimal("1000.00"), account.balance
    assert_equal 0, account.cash_balance
  end
end
