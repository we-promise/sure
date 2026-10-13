# frozen_string_literal: true

require "test_helper"

class CoinspotAccount::SecurityResolverTest < ActiveSupport::TestCase
  # The blank check used to run before the "|||" suffix was dropped, so a
  # symbol that is only a delimiter survived it and a symbol with whitespace
  # before the delimiter kept a trailing space -- both of which build a bad
  # "CRYPTO:" ticker.
  test "normalize_symbol drops the suffix before validating the remainder" do
    assert_nil CoinspotAccount::SecurityResolver.normalize_symbol("|||BTC")
    assert_equal "BTC", CoinspotAccount::SecurityResolver.normalize_symbol("BTC |||AUD")
  end

  test "normalize_symbol uppercases, trims, and rejects blanks" do
    assert_equal "BTC", CoinspotAccount::SecurityResolver.normalize_symbol(" btc ")
    assert_equal "ETH", CoinspotAccount::SecurityResolver.normalize_symbol("eth")
    assert_nil CoinspotAccount::SecurityResolver.normalize_symbol("")
    assert_nil CoinspotAccount::SecurityResolver.normalize_symbol(nil)
    assert_nil CoinspotAccount::SecurityResolver.normalize_symbol("   ")
  end

  # find_or_initialize_by checks before save!, so two overlapping syncs
  # resolving a new symbol can both miss and both insert. The unique index
  # rejects the loser, and that exception used to escape into a per-record
  # import failure instead of simply reading back the row that won.
  test "resolve reads back the placeholder when a concurrent insert wins the race" do
    existing = Security.create!(
      ticker: "CRYPTO:XYZ", name: "XYZ", exchange_operating_mic: "XCSO", offline: true
    )
    Security::Resolver.any_instance.stubs(:resolve).returns(nil)
    Security.stubs(:find_or_initialize_by).returns(
      Security.new(ticker: "CRYPTO:XYZ", exchange_operating_mic: "XCSO")
    )
    Security.any_instance.stubs(:save!).raises(ActiveRecord::RecordNotUnique.new("duplicate key"))

    assert_equal existing, CoinspotAccount::SecurityResolver.resolve("XYZ")
  end
end
