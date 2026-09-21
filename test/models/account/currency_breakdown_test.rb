require "test_helper"

class Account::CurrencyBreakdownTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @card = accounts(:credit_card)
    @card.entries.destroy_all
    @card.update!(currency: "PEN")
  end

  test "single-currency account has no breakdown" do
    create_transaction(account: @card, amount: 100, currency: "PEN")

    assert_not @card.multi_currency_breakdown?
    assert_empty @card.native_currency_balances
  end

  test "liability card reports native debt per currency" do
    create_transaction(account: @card, amount: 300, currency: "PEN")
    create_transaction(account: @card, amount: 50, currency: "USD")
    create_transaction(account: @card, amount: -20, currency: "USD")

    balances = @card.native_currency_balances.index_by { |m| m.currency.iso_code }

    assert_equal [ "PEN", "USD" ], balances.keys
    assert_equal 300, balances["PEN"].amount
    assert_equal 30, balances["USD"].amount
  end

  test "asset account flips sign" do
    account = accounts(:depository)
    account.entries.destroy_all
    create_transaction(account: account, amount: -100, currency: account.currency)
    create_transaction(account: account, amount: -10, currency: "EUR")

    balances = account.native_currency_balances.index_by { |m| m.currency.iso_code }

    assert_equal 100, balances[account.currency].amount
    assert_equal 10, balances["EUR"].amount
  end
end
