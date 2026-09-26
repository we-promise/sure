# frozen_string_literal: true

require "test_helper"

# Covers the Account factory shared by every crypto-exchange integration:
# `create_from_crypto_exchange_account`, reached through Kraken, Binance and
# CoinSpot.
class Account::CryptoExchangeCreationTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "USD")
  end

  # `create_and_sync` anchors a new account at the balance it was created with,
  # dated in the past. That is right for an account whose history the user will
  # type in, and wrong for an exchange: the processors import its ledger from
  # inception, so every imported entry lands on top of an opening balance equal
  # to what the account is worth today. On an exchange older than the default
  # anchor date the whole history is inflated by the present value.
  test "a Kraken exchange account opens at zero, not at its current value" do
    account = Account.create_from_kraken_account(kraken_account(current_balance: 1_000))

    assert account.has_opening_anchor?
    assert_equal 0, account.opening_anchor_balance
    assert_equal 1_000, account.balance
  end

  test "a Binance exchange account opens at zero, not at its current value" do
    account = Account.create_from_binance_account(binance_account(current_balance: 2_500))

    assert account.has_opening_anchor?
    assert_equal 0, account.opening_anchor_balance
    assert_equal 2_500, account.balance
  end

  private

    def kraken_account(current_balance:, currency: "USD")
      item = KrakenItem.create!(family: @family, name: "Kraken", api_key: "k", api_secret: "s")
      item.kraken_accounts.create!(
        name: "Kraken",
        account_id: "combined",
        account_type: "combined",
        currency: currency,
        current_balance: current_balance
      )
    end

    def binance_account(current_balance:, currency: "USD")
      item = BinanceItem.create!(family: @family, name: "Binance", api_key: "b", api_secret: "s")
      item.binance_accounts.create!(
        name: "Binance",
        account_type: "combined",
        currency: currency,
        current_balance: current_balance
      )
    end
end
