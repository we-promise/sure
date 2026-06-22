# frozen_string_literal: true

require "test_helper"

class KrakenAccount::LedgerProcessorTest < ActiveSupport::TestCase
  setup do
    @family  = families(:dylan_family)
    @account = @family.accounts.create!(
      name: "Kraken", balance: 0, currency: "USD",
      accountable: Crypto.new
    )
    @item = KrakenItem.create!(
      family: @family, name: "Kraken", api_key: "k", api_secret: "s"
    )
    @kraken_account = @item.kraken_accounts.create!(
      name: "Kraken", account_id: "combined", account_type: "combined", currency: "USD",
      current_balance: 0,
      raw_payload: {
        "asset_metadata" => { "XXBT" => { "altname" => "BTC" }, "ZUSD" => { "altname" => "USD" }, "ZEUR" => { "altname" => "EUR" } },
        "assets" => [ { "symbol" => "BTC", "price_usd" => "50000.00" } ]
      },
      raw_transactions_payload: { "trades" => {}, "ledgers" => {} }
    )
    @kraken_account.ensure_account_provider!(@account)
  end

  # ---------------------------------------------------------------------------
  # deposit
  # ---------------------------------------------------------------------------

  test "creates a deposit entry for a BTC deposit" do
    set_ledgers(
      "LABC01" => ledger_entry(type: "deposit", asset: "XXBT", amount: "0.10000000", fee: "0.00000000", time: 1_700_000_000)
    )

    assert_difference "@account.entries.count", 1 do
      process
    end

    entry = @account.entries.find_by(external_id: "kraken_ledger_LABC01", source: "kraken")
    assert entry, "deposit entry must exist"
    assert entry.amount.positive?, "deposit must be positive (inflow)"
    assert_equal "USD", entry.currency
    assert_match(/Deposit.*BTC/, entry.name)

    txn = entry.entryable
    assert_equal "funds_movement", txn.kind
    assert_equal "Contribution",   txn.investment_activity_label
    assert_equal "LABC01",         txn.extra.dig("kraken", "ledger_id")
    assert_equal "deposit",        txn.extra.dig("kraken", "type")
  end

  test "creates a deposit entry for a USD fiat deposit" do
    set_ledgers(
      "LUSD01" => ledger_entry(type: "deposit", asset: "ZUSD", amount: "1000.00", fee: "0.00", time: 1_700_000_000)
    )

    assert_difference "@account.entries.count", 1 do
      process
    end

    entry = @account.entries.find_by(external_id: "kraken_ledger_LUSD01", source: "kraken")
    assert entry
    assert_in_delta 1000.0, entry.amount.to_f, 0.01
    assert_match(/Deposit.*USD/, entry.name)
  end

  # ---------------------------------------------------------------------------
  # withdrawal
  # ---------------------------------------------------------------------------

  test "creates a withdrawal entry (negative amount)" do
    set_ledgers(
      "LWIT01" => ledger_entry(type: "withdrawal", asset: "ZUSD", amount: "-500.00", fee: "1.00", time: 1_700_000_000)
    )

    assert_difference "@account.entries.count", 1 do
      process
    end

    entry = @account.entries.find_by(external_id: "kraken_ledger_LWIT01", source: "kraken")
    assert entry
    assert entry.amount.negative?, "withdrawal must be negative (outflow)"
    assert_match(/Withdrawal.*USD/, entry.name)
    assert_equal "Withdrawal", entry.entryable.investment_activity_label
    assert_equal "funds_movement", entry.entryable.kind
  end

  # ---------------------------------------------------------------------------
  # staking
  # ---------------------------------------------------------------------------

  test "creates a staking reward entry" do
    set_ledgers(
      "LSTK01" => ledger_entry(type: "staking", asset: "XXBT", amount: "0.00050000", fee: "0.00", time: 1_700_000_000)
    )

    assert_difference "@account.entries.count", 1 do
      process
    end

    entry = @account.entries.find_by(external_id: "kraken_ledger_LSTK01", source: "kraken")
    assert entry
    assert entry.amount.positive?
    assert_match(/Staking reward.*BTC/, entry.name)
    assert_equal "Dividend", entry.entryable.investment_activity_label
    assert_equal "standard",  entry.entryable.kind
  end

  # ---------------------------------------------------------------------------
  # earn
  # ---------------------------------------------------------------------------

  test "creates an earn reward entry" do
    set_ledgers(
      "LERN01" => ledger_entry(type: "earn", asset: "ZUSD", amount: "5.00", fee: "0.00", time: 1_700_000_000)
    )

    assert_difference "@account.entries.count", 1 do
      process
    end

    entry = @account.entries.find_by(external_id: "kraken_ledger_LERN01", source: "kraken")
    assert entry
    assert_equal "Interest", entry.entryable.investment_activity_label
  end

  # ---------------------------------------------------------------------------
  # standalone fee
  # ---------------------------------------------------------------------------

  test "creates a fee entry (negative amount)" do
    set_ledgers(
      "LFEE01" => ledger_entry(type: "fee", asset: "ZUSD", amount: "-7.50", fee: "0.00", time: 1_700_000_000)
    )

    assert_difference "@account.entries.count", 1 do
      process
    end

    entry = @account.entries.find_by(external_id: "kraken_ledger_LFEE01", source: "kraken")
    assert entry
    assert entry.amount.negative?
    assert_equal "Fee", entry.entryable.investment_activity_label
  end

  # ---------------------------------------------------------------------------
  # skipped types
  # ---------------------------------------------------------------------------

  test "skips trade-type ledger entries (handled by TradesHistory)" do
    set_ledgers(
      "LTRD01" => ledger_entry(type: "trade", asset: "XXBT", amount: "-0.1", fee: "0.0", time: 1_700_000_000)
    )

    assert_no_difference "@account.entries.count" do
      process
    end
  end

  test "skips transfer-type ledger entries" do
    set_ledgers(
      "LTRN01" => ledger_entry(type: "transfer", asset: "XXBT", amount: "0.1", fee: "0.0", time: 1_700_000_000)
    )

    assert_no_difference "@account.entries.count" do
      process
    end
  end

  # ---------------------------------------------------------------------------
  # idempotency
  # ---------------------------------------------------------------------------

  test "does not duplicate entries on repeated processing" do
    set_ledgers(
      "LIDEM01" => ledger_entry(type: "deposit", asset: "ZUSD", amount: "100.00", fee: "0.00", time: 1_700_000_000)
    )

    process
    assert_no_difference "@account.entries.count" do
      process
    end
  end

  # ---------------------------------------------------------------------------
  # non-USD family currency (EUR example)
  # ---------------------------------------------------------------------------

  test "converts fiat USD amounts to non-USD family currency" do
    @family.update!(currency: "EUR")
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: Date.current, rate: 0.92)

    set_ledgers(
      "LEUR01" => ledger_entry(type: "deposit", asset: "ZUSD", amount: "1000.00", fee: "0.00", time: Time.current.to_i)
    )

    process

    entry = @account.entries.find_by(external_id: "kraken_ledger_LEUR01", source: "kraken")
    assert entry
    assert_equal "EUR", entry.currency
    assert_in_delta 920.0, entry.amount.to_f, 1.0
  end

  test "marks crypto entries as price_missing when no price data available" do
    set_raw_payload_assets([])   # no stored prices

    set_ledgers(
      "LNOPRICE" => ledger_entry(type: "deposit", asset: "XXBT", amount: "0.5", fee: "0.00", time: 1_700_000_000)
    )

    assert_difference "@account.entries.count", 1 do
      process
    end

    entry = @account.entries.find_by(external_id: "kraken_ledger_LNOPRICE", source: "kraken")
    assert entry
    assert_equal 0, entry.amount.to_f
    assert entry.entryable.extra.dig("kraken", "price_missing")
  end

  private

    def process
      KrakenAccount::LedgerProcessor.new(@kraken_account).process
    end

    def set_ledgers(ledgers)
      @kraken_account.update!(
        raw_transactions_payload: @kraken_account.raw_transactions_payload.merge("ledgers" => ledgers)
      )
    end

    def set_raw_payload_assets(assets)
      @kraken_account.update!(
        raw_payload: @kraken_account.raw_payload.merge("assets" => assets)
      )
    end

    def ledger_entry(type:, asset:, amount:, fee:, time:)
      {
        "refid"   => "S#{SecureRandom.hex(4).upcase}",
        "time"    => time,
        "type"    => type,
        "subtype" => "",
        "aclass"  => "currency",
        "asset"   => asset,
        "amount"  => amount,
        "fee"     => fee,
        "balance" => "1.00000000"
      }
    end
end
