require "test_helper"

class AccountIbkrCreationTest < ActiveSupport::TestCase
  fixtures :families, :ibkr_items, :ibkr_accounts

  test "uses interactive brokers account id as part of the default name" do
    ibkr_account = ibkr_accounts(:main_account)

    account = Account.create_from_ibkr_account(ibkr_account)

    assert_equal "Interactive Brokers (U1234567)", account.name
    assert_equal "Investment", account.accountable_type
    assert_equal "CHF", account.currency
  end

  test "falls back to provider name when ibkr account id is missing" do
    family = families(:empty)
    ibkr_item = ibkr_items(:empty_item)
    ibkr_account = ibkr_item.ibkr_accounts.create!(
      name: "Imported IBKR Account",
      ibkr_account_id: nil,
      currency: "USD"
    )

    account = Account.create_from_ibkr_account(ibkr_account)

    assert_equal "Interactive Brokers", account.name
    assert_equal family, account.family
  end
end
