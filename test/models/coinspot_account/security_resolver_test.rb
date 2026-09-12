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
end
