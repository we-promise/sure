# frozen_string_literal: true

require "test_helper"

class KrakenAccount::SecurityResolverTest < ActiveSupport::TestCase
  # ---------------------------------------------------------------------------
  # canonical_asset
  # ---------------------------------------------------------------------------

  test "canonicalises Kraken's legacy codes" do
    assert_equal "BTC", canonical("XXBT")
    assert_equal "BTC", canonical("XBT")
    assert_equal "ETH", canonical("XETH")
    assert_equal "EUR", canonical("ZEUR")
  end

  # A staked or bonded balance is the same asset in a different wallet. Left
  # in, "DOT28.S" resolves to a security of its own and the position is split.
  test "strips a staking or bonding suffix" do
    assert_equal "BTC", canonical("XBT.M")
    assert_equal "ETH", canonical("ETH2.S")
    assert_equal "DOT", canonical("DOT28.S")
  end

  # The balance payload reports bonded DOT with the suffix twice.
  test "strips a repeated suffix" do
    assert_equal "DOT", canonical("DOT28.S.S")
    assert_equal canonical("DOT28.S"), canonical("DOT28.S.S")
  end

  # A trailing digit is only a suffix when a dot follows it. LUNA2 is its own
  # asset, not a wallet variant of LUNA.
  test "leaves an asset whose name ends in a digit alone" do
    assert_equal "LUNA2", canonical("LUNA2")
  end

  test "accepts a symbol that already carries the ticker prefix" do
    assert_equal "ETH", canonical("CRYPTO:ETH")
  end

  # ---------------------------------------------------------------------------
  # resolve
  # ---------------------------------------------------------------------------

  test "one security per asset, whatever wallet it sits in" do
    spot   = KrakenAccount::SecurityResolver.resolve("XXBT")
    staked = KrakenAccount::SecurityResolver.resolve("XBT.M")

    assert_equal spot.id, staked.id
    assert_equal "CRYPTO:BTC", spot.ticker
  end

  test "binds a new security to the provider that can price a bare coin symbol" do
    security = KrakenAccount::SecurityResolver.resolve("XXBT")

    assert_equal KrakenAccount::SecurityResolver::PRICE_PROVIDER, security.price_provider
    assert_equal KrakenAccount::SecurityResolver::EXCHANGE_MIC, security.exchange_operating_mic
    assert_not security.offline?
  end

  # Another integration may have created the record first. Reusing it keeps one
  # asset in one security rather than one per integration.
  test "adopts an existing security instead of creating a second one" do
    existing = Security.create!(ticker: "CRYPTO:BTC", name: "BTC", offline: true)

    resolved = assert_no_difference -> { Security.count } do
      KrakenAccount::SecurityResolver.resolve("XXBT")
    end

    assert_equal existing.id, resolved.id
    assert_equal KrakenAccount::SecurityResolver::PRICE_PROVIDER, resolved.reload.price_provider
    assert_not resolved.offline?
  end

  # A provider another integration chose deliberately is left alone, and so is
  # an offline flag set under it.
  test "does not overwrite a price provider someone else set" do
    Security.create!(ticker: "CRYPTO:BTC", name: "BTC", price_provider: "yahoo_finance", offline: true)

    resolved = KrakenAccount::SecurityResolver.resolve("XXBT")

    assert_equal "yahoo_finance", resolved.price_provider
    assert resolved.offline?
  end

  # The uniqueness index is on (ticker, mic), so the same ticker can exist at
  # more than one venue -- the previous Kraken code created these at XKRA. The
  # one at the crypto venue wins; failing that the oldest, so the choice does
  # not move between syncs.
  test "prefers the security at the crypto venue when the ticker exists at several" do
    Security.create!(ticker: "CRYPTO:BTC", name: "BTC", exchange_operating_mic: "XKRA", offline: true)
    venue = Security.create!(ticker: "CRYPTO:BTC", name: "BTC", exchange_operating_mic: KrakenAccount::SecurityResolver::EXCHANGE_MIC)

    assert_equal venue.id, KrakenAccount::SecurityResolver.resolve("XXBT").id
  end

  test "falls back to the oldest security for the ticker" do
    oldest = Security.create!(ticker: "CRYPTO:BTC", name: "BTC", exchange_operating_mic: "XKRA", created_at: 2.days.ago)
    Security.create!(ticker: "CRYPTO:BTC", name: "BTC", exchange_operating_mic: "XNAS", created_at: 1.day.ago)

    assert_equal oldest.id, KrakenAccount::SecurityResolver.resolve("XXBT").id
  end

  private

    def canonical(symbol)
      KrakenAccount::SecurityResolver.canonical_asset(symbol)
    end
end
