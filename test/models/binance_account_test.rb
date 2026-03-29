# frozen_string_literal: true

require "test_helper"

class BinanceAccountTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = BinanceItem.create!(
      family: @family, name: "Binance", api_key: "k", api_secret: "s"
    )
    @ba = @item.binance_accounts.create!(
      name: "Binance", account_type: "combined", currency: "USD", current_balance: 1000
    )
  end

  test "belongs to binance_item" do
    assert_equal @item, @ba.binance_item
  end

  test "validates presence of name" do
    ba = @item.binance_accounts.build(account_type: "combined", currency: "USD")
    assert_not ba.valid?
    assert_includes ba.errors[:name], "can't be blank"
  end

  test "validates presence of currency" do
    ba = @item.binance_accounts.build(name: "Binance", account_type: "combined")
    assert_not ba.valid?
    assert_includes ba.errors[:currency], "can't be blank"
  end

  test "ensure_account_provider! creates AccountProvider" do
    account = Account.create!(
      family: @family, name: "Binance", balance: 0, currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    @ba.ensure_account_provider!(account)

    ap = AccountProvider.find_by(provider: @ba)
    assert_not_nil ap
    assert_equal account, ap.account
  end

  test "ensure_account_provider! is idempotent" do
    account = Account.create!(
      family: @family, name: "Binance", balance: 0, currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    @ba.ensure_account_provider!(account)
    @ba.ensure_account_provider!(account)

    assert_equal 1, AccountProvider.where(provider: @ba).count
  end

  test "current_account returns linked account" do
    assert_nil @ba.current_account

    account = Account.create!(
      family: @family, name: "Binance", balance: 0, currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: account, provider: @ba)

    assert_equal account, @ba.reload.current_account
  end
end
