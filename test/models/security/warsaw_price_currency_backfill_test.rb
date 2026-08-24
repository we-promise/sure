require "test_helper"

class Security::WarsawPriceCurrencyBackfillTest < ActiveSupport::TestCase
  setup do
    @security = Security.create!(ticker: "KTY", exchange_operating_mic: "XWAR", country_code: "PL")
  end

  test "relabels USD Warsaw prices to PLN" do
    usd = Security::Price.create!(security: @security, date: Date.new(2026, 8, 21), price: 1213, currency: "USD")

    result = Security::WarsawPriceCurrencyBackfill.new(dry_run: false, sync_accounts: false).call

    assert_equal 1, result.prices_relabeled
    assert_equal 0, result.prices_deleted
    assert_equal "PLN", usd.reload.currency
  end

  test "deletes USD duplicate when PLN already exists for the same date" do
    Security::Price.create!(security: @security, date: Date.new(2026, 8, 21), price: 1213, currency: "PLN")
    usd = Security::Price.create!(security: @security, date: Date.new(2026, 8, 21), price: 1213, currency: "USD")

    result = Security::WarsawPriceCurrencyBackfill.new(dry_run: false, sync_accounts: false).call

    assert_equal 0, result.prices_relabeled
    assert_equal 1, result.prices_deleted
    assert_not Security::Price.exists?(usd.id)
    assert_equal 1, @security.prices.where(date: Date.new(2026, 8, 21), currency: "PLN").count
  end

  test "canonicalizes legacy WAR MIC to XWAR when no conflict" do
    legacy = Security.create!(ticker: "PKO", exchange_operating_mic: "XWAR", country_code: "PL")
    legacy.update_columns(exchange_operating_mic: "WAR")
    Security::Price.create!(security: legacy, date: Date.new(2026, 8, 21), price: 50, currency: "USD")

    result = Security::WarsawPriceCurrencyBackfill.new(dry_run: false, sync_accounts: false).call

    assert_operator result.mics_canonicalized, :>=, 1
    assert_equal "XWAR", legacy.reload.exchange_operating_mic
    assert_equal "PLN", legacy.prices.first.currency
  end

  test "dry run does not mutate rows" do
    usd = Security::Price.create!(security: @security, date: Date.new(2026, 8, 21), price: 1213, currency: "USD")

    result = Security::WarsawPriceCurrencyBackfill.new(dry_run: true, sync_accounts: false).call

    assert result.dry_run
    assert_equal 1, result.prices_relabeled
    assert_equal "USD", usd.reload.currency
  end

  test "does not touch non-Warsaw securities" do
    other = Security.create!(ticker: "AAPL", exchange_operating_mic: "XNAS", country_code: "US")
    usd = Security::Price.create!(security: other, date: Date.new(2026, 8, 21), price: 200, currency: "USD")

    Security::WarsawPriceCurrencyBackfill.new(dry_run: false, sync_accounts: false).call

    assert_equal "USD", usd.reload.currency
  end

  test "queues account syncs for holdings of touched securities" do
    account = accounts(:investment)
    Security::Price.create!(security: @security, date: Date.new(2026, 8, 21), price: 1213, currency: "USD")
    Holding.create!(
      account: account,
      security: @security,
      date: Date.new(2026, 8, 21),
      qty: 1,
      price: 1213,
      amount: 1213,
      currency: "USD"
    )

    Account.any_instance.expects(:sync_later).at_least_once

    result = Security::WarsawPriceCurrencyBackfill.new(dry_run: false, sync_accounts: true).call

    assert_operator result.accounts_queued_for_sync, :>=, 1
  end

  test "requeues account sync on retry for already corrected Warsaw securities" do
    account = accounts(:investment)
    Security::Price.create!(security: @security, date: Date.new(2026, 8, 21), price: 1213, currency: "PLN")
    Holding.create!(
      account: account,
      security: @security,
      date: Date.new(2026, 8, 21),
      qty: 1,
      price: 1213,
      amount: 1213,
      currency: "PLN"
    )

    Account.any_instance.expects(:sync_later).at_least_once

    result = Security::WarsawPriceCurrencyBackfill.new(dry_run: false, sync_accounts: true).call

    assert_equal 0, result.prices_relabeled
    assert_operator result.accounts_queued_for_sync, :>=, 1
  end

  test "skips MIC upgrade when both WAR and XWAR securities already exist" do
    canonical = Security.create!(ticker: "PZU", exchange_operating_mic: "XWAR", country_code: "PL")
    legacy = Security.new(ticker: "PZU", exchange_operating_mic: "WAR", country_code: "PL")
    legacy.save!(validate: false)
    Security::Price.create!(security: legacy, date: Date.new(2026, 8, 21), price: 40, currency: "USD")

    result = Security::WarsawPriceCurrencyBackfill.new(dry_run: false, sync_accounts: false).call

    assert_equal "WAR", legacy.reload.exchange_operating_mic
    assert_equal "XWAR", canonical.reload.exchange_operating_mic
    assert_equal "PLN", legacy.prices.first.currency
    assert_equal 0, result.mics_canonicalized
  end
end
