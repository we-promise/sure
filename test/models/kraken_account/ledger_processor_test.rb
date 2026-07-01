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
  # sign convention: Sure uses negative = inflow, positive = outflow
  # ---------------------------------------------------------------------------

  test "creates a deposit entry with negative amount (inflow)" do
    set_ledgers(
      "LABC01" => ledger_entry(type: "deposit", asset: "ZUSD", amount: "1000.00", fee: "0.00", time: 1_700_000_000)
    )

    assert_difference "@account.entries.count", 1 do
      process
    end

    entry = @account.entries.find_by(external_id: "kraken_ledger_LABC01", source: "kraken")
    assert entry, "deposit entry must exist"
    assert entry.amount.negative?, "deposit is an inflow — must be negative in Sure's convention"
    assert_in_delta(-1000.0, entry.amount.to_f, 0.01)
    assert_equal "USD", entry.currency
    assert_match(/Deposit.*USD/, entry.name)

    txn = entry.entryable
    assert_equal "funds_movement", txn.kind
    assert_equal "Contribution",   txn.investment_activity_label
    assert_equal "LABC01",         txn.extra.dig("kraken", "ledger_id")
    assert_equal "deposit",        txn.extra.dig("kraken", "type")
  end

  test "creates a withdrawal entry with positive amount (outflow)" do
    set_ledgers(
      "LWIT01" => ledger_entry(type: "withdrawal", asset: "ZUSD", amount: "-500.00", fee: "0.00", time: 1_700_000_000)
    )

    assert_difference "@account.entries.count", 1 do
      process
    end

    entry = @account.entries.find_by(external_id: "kraken_ledger_LWIT01", source: "kraken")
    assert entry
    assert entry.amount.positive?, "withdrawal is an outflow — must be positive in Sure's convention"
    assert_in_delta 500.0, entry.amount.to_f, 0.01
    assert_match(/Withdrawal.*USD/, entry.name)
    assert_equal "Withdrawal",    entry.entryable.investment_activity_label
    assert_equal "funds_movement", entry.entryable.kind
  end

  # ---------------------------------------------------------------------------
  # fee inclusion in amount
  # ---------------------------------------------------------------------------

  test "includes the Kraken fee in the total withdrawal amount" do
    # Kraken: balance_change = amount - fee = -500 - 1 = -501 total outflow
    set_ledgers(
      "LWIT02" => ledger_entry(type: "withdrawal", asset: "ZUSD", amount: "-500.00", fee: "1.00", time: 1_700_000_000)
    )

    process

    entry = @account.entries.find_by(external_id: "kraken_ledger_LWIT02", source: "kraken")
    assert entry
    assert_in_delta 501.0, entry.amount.to_f, 0.01
  end

  # ---------------------------------------------------------------------------
  # BTC deposit (crypto → family currency conversion)
  # ---------------------------------------------------------------------------

  test "creates a deposit entry for BTC using stored price" do
    set_ledgers(
      "LBTC01" => ledger_entry(type: "deposit", asset: "XXBT", amount: "0.10000000", fee: "0.00000000", time: 1_700_000_000)
    )

    process

    entry = @account.entries.find_by(external_id: "kraken_ledger_LBTC01", source: "kraken")
    assert entry
    assert entry.amount.negative?, "BTC deposit is an inflow — must be negative"
    # 0.1 BTC × $50,000/BTC = $5,000 (family currency = USD, no conversion needed)
    assert_in_delta(-5000.0, entry.amount.to_f, 1.0)
    assert_match(/Deposit.*BTC/, entry.name)
  end

  # ---------------------------------------------------------------------------
  # staking
  # ---------------------------------------------------------------------------

  test "creates a staking reward entry (negative = inflow)" do
    set_ledgers(
      "LSTK01" => ledger_entry(type: "staking", asset: "XXBT", amount: "0.00050000", fee: "0.00", time: 1_700_000_000)
    )

    assert_difference "@account.entries.count", 1 do
      process
    end

    entry = @account.entries.find_by(external_id: "kraken_ledger_LSTK01", source: "kraken")
    assert entry
    assert entry.amount.negative?, "staking reward is an inflow — must be negative"
    assert_match(/Staking reward.*BTC/, entry.name)
    assert_equal "Dividend", entry.entryable.investment_activity_label
    assert_equal "standard",  entry.entryable.kind
  end

  # ---------------------------------------------------------------------------
  # earn
  # ---------------------------------------------------------------------------

  test "creates an earn reward entry for rewards subtype" do
    set_ledgers(
      "LERN01" => ledger_entry(type: "earn", subtype: "rewardallocation", asset: "ZUSD", amount: "5.00", fee: "0.00", time: 1_700_000_000)
    )

    assert_difference "@account.entries.count", 1 do
      process
    end

    entry = @account.entries.find_by(external_id: "kraken_ledger_LERN01", source: "kraken")
    assert entry
    assert entry.amount.negative?, "earn reward is an inflow — must be negative"
    assert_equal "Interest", entry.entryable.investment_activity_label
  end

  test "skips earn allocation entries (internal fund movement, not income)" do
    set_ledgers(
      "LALLOC" => ledger_entry(type: "earn", subtype: "allocation", asset: "ZUSD", amount: "500.00", fee: "0.00", time: 1_700_000_000),
      "LDEALLOC" => ledger_entry(type: "earn", subtype: "deallocation", asset: "ZUSD", amount: "-500.00", fee: "0.00", time: 1_700_000_000)
    )

    assert_no_difference "@account.entries.count" do
      process
    end
  end

  # ---------------------------------------------------------------------------
  # standalone fee
  # ---------------------------------------------------------------------------

  test "creates a fee entry with positive amount (outflow)" do
    set_ledgers(
      "LFEE01" => ledger_entry(type: "fee", asset: "ZUSD", amount: "-7.50", fee: "0.00", time: 1_700_000_000)
    )

    assert_difference "@account.entries.count", 1 do
      process
    end

    entry = @account.entries.find_by(external_id: "kraken_ledger_LFEE01", source: "kraken")
    assert entry
    assert entry.amount.positive?, "fee is an outflow — must be positive"
    assert_in_delta 7.5, entry.amount.to_f, 0.01
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

    # First pass must actually create the entry...
    assert_difference "@account.entries.count", 1 do
      process
    end

    # ...and a second pass must be a no-op.
    assert_no_difference "@account.entries.count" do
      process
    end
  end

  test "idempotency check does not scale entries queries with ledger count" do
    set_ledgers(
      "LQ1" => ledger_entry(type: "deposit", asset: "ZUSD", amount: "10.00", fee: "0.00", time: 1_700_000_000),
      "LQ2" => ledger_entry(type: "deposit", asset: "ZUSD", amount: "20.00", fee: "0.00", time: 1_700_000_100),
      "LQ3" => ledger_entry(type: "deposit", asset: "ZUSD", amount: "30.00", fee: "0.00", time: 1_700_000_200)
    )

    process # first pass creates the 3 entries
    assert_equal 3, @account.entries.count

    # On a second pass every entry is already present, so all are skipped. The
    # existence check must be a single bulk pluck regardless of ledger count —
    # the previous per-entry `exists?` would issue one query per entry instead.
    queries = capture_sql_queries { process }
    entries_selects = queries.count { |q| q.match?(/from "entries"/i) }
    assert_equal 1, entries_selects,
      "second pass should issue exactly one bulk external_id pluck, not one per entry"
  end

  # ---------------------------------------------------------------------------
  # non-USD family currency
  # ---------------------------------------------------------------------------

  test "converts USD deposit to non-USD family currency" do
    @family.update!(currency: "EUR")
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: Date.current, rate: 0.92)

    set_ledgers(
      "LEUR01" => ledger_entry(type: "deposit", asset: "ZUSD", amount: "1000.00", fee: "0.00", time: Time.current.to_i)
    )

    process

    entry = @account.entries.find_by(external_id: "kraken_ledger_LEUR01", source: "kraken")
    assert entry
    assert_equal "EUR", entry.currency
    assert entry.amount.negative?, "deposit is inflow — negative"
    assert_in_delta(-920.0, entry.amount.to_f, 1.0)
  end

  # ---------------------------------------------------------------------------
  # missing crypto price
  # ---------------------------------------------------------------------------

  test "records zero amount and price_missing flag when no price data available" do
    set_raw_payload_assets([])

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

    def ledger_entry(type:, asset:, amount:, fee:, time:, subtype: "")
      {
        "refid"   => "S#{SecureRandom.hex(4).upcase}",
        "time"    => time,
        "type"    => type,
        "subtype" => subtype,
        "aclass"  => "currency",
        "asset"   => asset,
        "amount"  => amount,
        "fee"     => fee,
        "balance" => "1.00000000"
      }
    end
end
