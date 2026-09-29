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
  # fee handling
  # ---------------------------------------------------------------------------

  # A withdrawal has a counterparty. The receiving bank records 500, not 501,
  # and `Transfer` requires both legs to sum to zero -- so a withdrawal carrying
  # Kraken's fee can never be matched. The fee becomes its own entry instead;
  # together the two still move the balance by the 501 Kraken applied.
  test "a withdrawal fee is charged as its own entry" do
    set_ledgers(
      "LWIT02" => ledger_entry(type: "withdrawal", asset: "ZUSD", amount: "-500.00", fee: "1.00", time: 1_700_000_000)
    )

    assert_difference "@account.entries.count", 2 do
      process
    end

    principal = @account.entries.find_by(external_id: "kraken_ledger_LWIT02", source: "kraken")
    assert principal
    assert_in_delta 500.0, principal.amount.to_f, 0.01

    fee = @account.entries.find_by(external_id: "kraken_ledger_LWIT02_fee", source: "kraken")
    assert fee, "the fee must be its own entry"
    assert_in_delta 1.0, fee.amount.to_f, 0.01
    assert_equal "Fee 1 USD", fee.name, "a BigDecimal must not reach the name as 0.1e1"
    assert_equal "Fee", fee.entryable.investment_activity_label
    assert_in_delta 501.0, principal.amount.to_f + fee.amount.to_f, 0.01
  end

  # The fee is a cost whichever way the principal moved, so it is an outflow on
  # a deposit too.
  test "a deposit fee is charged as its own outflow" do
    set_ledgers(
      "LDEP02" => ledger_entry(type: "deposit", asset: "ZUSD", amount: "1000.00", fee: "2.00", time: 1_700_000_000)
    )

    assert_difference "@account.entries.count", 2 do
      process
    end

    principal = @account.entries.find_by(external_id: "kraken_ledger_LDEP02", source: "kraken")
    assert_in_delta(-1000.0, principal.amount.to_f, 0.01)

    fee = @account.entries.find_by(external_id: "kraken_ledger_LDEP02_fee", source: "kraken")
    assert fee
    assert fee.amount.positive?, "a fee is always an outflow"
    assert_in_delta 2.0, fee.amount.to_f, 0.01
  end

  # Only deposits and withdrawals have a counterparty to reconcile against.
  # Everything else keeps the combined figure.
  test "a fee on a ledger type with no counterparty stays folded in" do
    set_ledgers(
      "LSTK02" => ledger_entry(type: "staking", asset: "ZUSD", amount: "10.00", fee: "1.00", time: 1_700_000_000)
    )

    assert_difference "@account.entries.count", 1 do
      process
    end

    entry = @account.entries.find_by(external_id: "kraken_ledger_LSTK02", source: "kraken")
    assert_in_delta(-9.0, entry.amount.to_f, 0.01)
  end

  # Pricing the fee can fail on one sync and succeed on the next. The principal
  # being present must not stop the fee from being created later.
  test "a fee missing after an earlier pass is created without duplicating the principal" do
    @account.entries.create!(
      date: Time.zone.at(1_700_000_000).to_date, name: "Withdrawal 500.0 USD", amount: 500, currency: "USD",
      external_id: "kraken_ledger_LWIT05", source: "kraken",
      entryable: Transaction.new(kind: "funds_movement", investment_activity_label: "Withdrawal")
    )
    set_ledgers(
      "LWIT05" => ledger_entry(type: "withdrawal", asset: "ZUSD", amount: "-500.00", fee: "1.00", time: 1_700_000_000)
    )

    assert_difference "@account.entries.count", 1 do
      process
    end

    assert_equal 1, @account.entries.where(external_id: "kraken_ledger_LWIT05").count
    fee = @account.entries.find_by(external_id: "kraken_ledger_LWIT05_fee", source: "kraken")
    assert fee
    assert_in_delta 1.0, fee.amount.to_f, 0.01
  end

  # A correction row can carry a fee against a zero principal. Before the fee
  # was split out the combined figure kept it; now the fee is its own entry and
  # a zero principal must not swallow it.
  test "a fee-only ledger row still produces its fee entry" do
    set_ledgers(
      "LWIT06" => ledger_entry(type: "withdrawal", asset: "ZUSD", amount: "0.00", fee: "0.50", time: 1_700_000_000)
    )

    assert_difference "@account.entries.count", 1 do
      process
    end

    assert_nil @account.entries.find_by(external_id: "kraken_ledger_LWIT06"), "no principal for a zero amount"
    fee = @account.entries.find_by(external_id: "kraken_ledger_LWIT06_fee", source: "kraken")
    assert fee
    assert_in_delta 0.5, fee.amount.to_f, 0.01
  end

  # An account synced before fees were split carries the fee inside the
  # withdrawal. An ordinary sync reaches it long before the re-import this
  # change asks for, and must not charge the fee a second time.
  test "a principal written with its fee inside it is left alone" do
    set_ledgers(
      "LWIT07" => ledger_entry(type: "withdrawal", asset: "ZUSD", amount: "-500.00", fee: "1.00", time: 1_700_000_000)
    )
    legacy = @account.entries.create!(
      date: Time.zone.at(1_700_000_000).to_date,
      name: "Withdrawal 501 USD",
      amount: 501,
      currency: "USD",
      external_id: "kraken_ledger_LWIT07",
      source: "kraken",
      entryable: Transaction.new
    )

    assert_no_difference "@account.entries.count" do
      process
    end

    assert_nil @account.entries.find_by(external_id: "kraken_ledger_LWIT07_fee")
    assert_equal 501, legacy.reload.amount
  end

  # The other reason a principal can stand alone: pricing the fee failed on an
  # earlier sync. That one is still owed its other half.
  test "a principal written without its fee still gets one" do
    set_ledgers(
      "LWIT08" => ledger_entry(type: "withdrawal", asset: "ZUSD", amount: "-500.00", fee: "1.00", time: 1_700_000_000)
    )
    @account.entries.create!(
      date: Time.zone.at(1_700_000_000).to_date,
      name: "Withdrawal 500 USD",
      amount: 500,
      currency: "USD",
      external_id: "kraken_ledger_LWIT08",
      source: "kraken",
      entryable: Transaction.new
    )

    assert_difference "@account.entries.count", 1 do
      process
    end

    fee = @account.entries.find_by(external_id: "kraken_ledger_LWIT08_fee", source: "kraken")
    assert fee
    assert_in_delta 1.0, fee.amount.to_f, 0.01
  end

  # A crypto principal is converted at the current spot price, so the stored
  # figure and anything recomputed later drift apart as the price moves. The
  # native quantity does not, which is why the classification reads that.
  test "a crypto principal written with its fee inside it survives a price move" do
    set_raw_payload_assets([ { "symbol" => "BTC", "price_usd" => "50000.00" } ])
    set_ledgers(
      "LWBTC1" => ledger_entry(type: "withdrawal", asset: "XXBT", amount: "-0.50000000", fee: "0.00100000", time: 1_700_000_000)
    )
    # As the old code wrote it: one entry for 0.501 BTC, priced at 50,000.
    @account.entries.create!(
      date: Time.zone.at(1_700_000_000).to_date,
      name: "Withdrawal 0.501 BTC",
      amount: 25_050,
      currency: "USD",
      external_id: "kraken_ledger_LWBTC1",
      source: "kraken",
      entryable: Transaction.new
    )

    # Upwards: the stored figure now sits nearer the fee-less candidate than the
    # fee-inclusive one, which is what a comparison of converted amounts reads
    # as "still owed its fee".
    set_raw_payload_assets([ { "symbol" => "BTC", "price_usd" => "60000.00" } ])

    assert_no_difference "@account.entries.count" do
      process
    end

    assert_nil @account.entries.find_by(external_id: "kraken_ledger_LWBTC1_fee")
  end

  # The legacy check must not cost a query per ledger row: the principal
  # amounts are loaded with the external ids, in the same bulk read.
  test "the legacy-principal check does not scale entries queries with ledger count" do
    set_ledgers(
      "LWQ1" => ledger_entry(type: "withdrawal", asset: "ZUSD", amount: "-100.00", fee: "1.00", time: 1_700_000_000),
      "LWQ2" => ledger_entry(type: "withdrawal", asset: "ZUSD", amount: "-200.00", fee: "1.00", time: 1_700_000_100),
      "LWQ3" => ledger_entry(type: "withdrawal", asset: "ZUSD", amount: "-300.00", fee: "1.00", time: 1_700_000_200)
    )

    process
    queries = capture_sql_queries { process }
    entries_selects = queries.count { |q| q.match?(/from "entries"/i) }
    assert_equal 1, entries_selects,
      "second pass should still issue exactly one bulk read, not one per split-fee row"
  end

  test "a split fee entry is not duplicated on reprocessing" do
    set_ledgers(
      "LWIT03" => ledger_entry(type: "withdrawal", asset: "ZUSD", amount: "-500.00", fee: "1.00", time: 1_700_000_000)
    )

    assert_difference "@account.entries.count", 2 do
      process
    end

    assert_no_difference "@account.entries.count" do
      process
    end
  end

  # ---------------------------------------------------------------------------
  # crypto moves units, not cash
  # ---------------------------------------------------------------------------

  # A coin deposit is a position change with no cash leg. Recorded as a
  # Transaction the quantity is lost, so the holdings calculator has nothing to
  # reverse and the cash balance moves by an amount that never existed.
  test "a BTC deposit becomes a trade carrying the quantity, not a cash entry" do
    set_ledgers(
      "LBTC01" => ledger_entry(type: "deposit", asset: "XXBT", amount: "0.10000000", fee: "0.00000000", time: 1_700_000_000)
    )

    process

    entry = @account.entries.find_by(external_id: "kraken_ledger_LBTC01", source: "kraken")
    assert entry
    assert_equal "Trade", entry.entryable_type
    assert_equal 0, entry.amount, "a coin movement has no cash leg"
    assert_in_delta 0.1, entry.entryable.qty.to_f, 1e-8
    assert_equal "CRYPTO:BTC", entry.entryable.security.ticker
    # A coin arriving from outside has a cost nothing here knows.
    assert_equal Trade::TRANSFER_LABEL, entry.entryable.investment_activity_label
    assert_match(/Deposit.*BTC/, entry.name)
  end

  # Pricing can fail on one sync and succeed on the next. A trade recorded at
  # zero with the flag is completed once the price on its date exists.
  test "a crypto trade recorded without a price is priced on a later sync" do
    set_raw_payload_assets([])
    set_ledgers(
      "LBTC20" => ledger_entry(type: "deposit", asset: "XXBT", amount: "0.10000000", fee: "0.00000000", time: 1_700_000_000)
    )
    process
    trade = @account.entries.find_by(external_id: "kraken_ledger_LBTC20", source: "kraken").entryable
    assert_equal 0, trade.price
    assert trade.extra.dig("kraken", "price_missing"), "recorded without a price"

    Security::Price.create!(security: trade.security, date: Time.zone.at(1_700_000_000).to_date, price: 40_000, currency: "USD")

    assert_no_difference "@account.entries.count" do
      process
    end

    trade.reload
    assert_in_delta 40_000.0, trade.price.to_f, 0.01
    assert_nil trade.extra.dig("kraken", "price_missing")
  end

  # An account synced before this change holds the coin movement as a
  # Transaction: a cash leg that never existed, and a quantity the holdings never
  # saw. A plain sync replaces it, so nobody has to re-import to be right.
  test "a legacy crypto transaction is replaced by the trade on the next sync" do
    set_ledgers(
      "LBTC10" => ledger_entry(type: "deposit", asset: "XXBT", amount: "0.10000000", fee: "0.00000000", time: 1_700_000_000)
    )
    legacy = @account.entries.create!(
      date: Time.zone.at(1_700_000_000).to_date, name: "Deposit 0.1 BTC", amount: -4_000, currency: "EUR",
      external_id: "kraken_ledger_LBTC10", source: "kraken",
      entryable: Transaction.new(kind: "funds_movement")
    )

    assert_no_difference "@account.entries.count" do
      process
    end

    assert_nil Entry.find_by(id: legacy.id), "the old cash row must be gone"
    entry = @account.entries.find_by(external_id: "kraken_ledger_LBTC10", source: "kraken")
    assert_equal "Trade", entry.entryable_type
    assert_equal 0, entry.amount
    assert_in_delta 0.1, entry.entryable.qty.to_f, 1e-8
  end

  # A row somebody has matched into a transfer, or edited, is theirs: it stays
  # as it is even though it is the old shape.
  test "a legacy crypto transaction in a transfer, or edited, is left alone" do
    set_ledgers(
      "LBTC11" => ledger_entry(type: "withdrawal", asset: "XXBT", amount: "-0.05000000", fee: "0.00000000", time: 1_700_000_000),
      "LBTC12" => ledger_entry(type: "deposit", asset: "XXBT", amount: "0.02000000", fee: "0.00000000", time: 1_700_000_100)
    )
    outflow = @account.entries.create!(
      date: Time.zone.at(1_700_000_000).to_date, name: "Withdrawal 0.05 BTC", amount: 2_000, currency: "EUR",
      external_id: "kraken_ledger_LBTC11", source: "kraken", entryable: Transaction.new(kind: "funds_movement")
    )
    # A transfer needs the other leg on another account of the same family.
    wallet = @account.family.accounts.create!(name: "Cold wallet", balance: 0, currency: "EUR", accountable: Depository.new)
    inflow = wallet.entries.create!(
      date: Time.zone.at(1_700_000_000).to_date, name: "Received 0.05 BTC", amount: -2_000, currency: "EUR",
      entryable: Transaction.new(kind: "funds_movement")
    )
    Transfer.create!(inflow_transaction: inflow.entryable, outflow_transaction: outflow.entryable)
    edited = @account.entries.create!(
      date: Time.zone.at(1_700_000_100).to_date, name: "Deposit 0.02 BTC", amount: -800, currency: "EUR",
      external_id: "kraken_ledger_LBTC12", source: "kraken", user_modified: true,
      entryable: Transaction.new(kind: "funds_movement")
    )

    assert_no_difference "@account.entries.count" do
      process
    end

    assert_equal "Transaction", outflow.reload.entryable_type
    assert_equal 2_000, outflow.amount
    assert_equal "Transaction", edited.reload.entryable_type
    assert_equal(-800, edited.amount)
  end

  # The price is the one on the day the units moved, read from the prices
  # already in the database; the provider is asked once per asset for the
  # whole span, not once per entry.
  test "a crypto trade is priced from the stored price on its date" do
    security = Security.create!(ticker: "CRYPTO:BTC", name: "BTC")
    Security::Price.create!(security: security, date: Time.zone.at(1_700_000_000).to_date, price: 40_000, currency: "USD")
    Security.any_instance.expects(:find_or_fetch_price).never

    set_ledgers(
      "LBTC03" => ledger_entry(type: "staking", asset: "XXBT", amount: "0.00100000", fee: "0.00", time: 1_700_000_000)
    )

    process

    trade = @account.entries.find_by(external_id: "kraken_ledger_LBTC03", source: "kraken").entryable
    assert_in_delta 40_000.0, trade.price.to_f, 0.01
    assert_not trade.extra.dig("kraken", "price_missing")
  end

  test "a BTC withdrawal becomes a trade that gives up units" do
    set_ledgers(
      "LBTC02" => ledger_entry(type: "withdrawal", asset: "XXBT", amount: "-0.20000000", fee: "0.00000000", time: 1_700_000_000)
    )

    process

    entry = @account.entries.find_by(external_id: "kraken_ledger_LBTC02", source: "kraken")
    assert_equal "Trade", entry.entryable_type
    assert_equal 0, entry.amount
    assert_in_delta(-0.2, entry.entryable.qty.to_f, 1e-8)
  end

  # A fiat deposit still has a cash leg and stays a Transaction.
  test "a fiat deposit is still a cash entry" do
    set_ledgers(
      "LUSD01" => ledger_entry(type: "deposit", asset: "ZUSD", amount: "250.00", fee: "0.00", time: 1_700_000_000)
    )

    process

    entry = @account.entries.find_by(external_id: "kraken_ledger_LUSD01", source: "kraken")
    assert_equal "Transaction", entry.entryable_type
    assert_in_delta(-250.0, entry.amount.to_f, 0.01)
  end

  # ---------------------------------------------------------------------------
  # staking
  # ---------------------------------------------------------------------------

  # A staking reward pays coins, not euros. It is acquired at the market price
  # on the day, which is both its basis and the income it represents.
  test "a crypto staking reward becomes a trade that adds units" do
    set_ledgers(
      "LSTK01" => ledger_entry(type: "staking", asset: "XXBT", amount: "0.00050000", fee: "0.00", time: 1_700_000_000)
    )

    assert_difference "@account.entries.count", 1 do
      process
    end

    entry = @account.entries.find_by(external_id: "kraken_ledger_LSTK01", source: "kraken")
    assert entry
    assert_equal "Trade", entry.entryable_type
    assert_equal 0, entry.amount
    assert_in_delta 0.0005, entry.entryable.qty.to_f, 1e-9
    assert_match(/Staking reward.*BTC/, entry.name)
    assert_equal "Dividend", entry.entryable.investment_activity_label
  end

  test "a fiat staking reward is still a cash entry" do
    set_ledgers(
      "LSTK03" => ledger_entry(type: "staking", asset: "ZUSD", amount: "4.00", fee: "0.00", time: 1_700_000_000)
    )

    process

    entry = @account.entries.find_by(external_id: "kraken_ledger_LSTK03", source: "kraken")
    assert_equal "Transaction", entry.entryable_type
    assert_in_delta(-4.0, entry.amount.to_f, 0.01)
    assert_equal "standard", entry.entryable.kind
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
  # dust sweep
  # ---------------------------------------------------------------------------

  # "Convert small balances" emits a spend and a receive. Neither type was
  # listed as supported or as skipped, so both fell through the guard and were
  # dropped without a trace -- a swept position stayed on the books at its
  # pre-sweep quantity forever.
  test "imports both halves of a dust sweep" do
    set_ledgers(
      "LSWP01" => ledger_entry(type: "spend",   asset: "XXBT", amount: "-0.00010000", fee: "0.00", time: 1_700_000_000),
      "LSWP02" => ledger_entry(type: "receive", asset: "XXBT", amount: "0.00004000",  fee: "0.00", time: 1_700_000_000)
    )

    assert_difference "@account.entries.count", 2 do
      process
    end

    spent = @account.entries.find_by(external_id: "kraken_ledger_LSWP01", source: "kraken")
    assert_in_delta(-0.0001, spent.entryable.qty.to_f, 1e-9)
    assert_match(/Converted/, spent.name)

    received = @account.entries.find_by(external_id: "kraken_ledger_LSWP02", source: "kraken")
    assert_in_delta 0.00004, received.entryable.qty.to_f, 1e-9
    assert_match(/Received/, received.name)
  end

  # Both halves stay inside the exchange, so neither invents a cost basis.
  test "a dust sweep is an internal movement on both sides" do
    set_ledgers(
      "LSWP03" => ledger_entry(type: "spend",   asset: "XXBT", amount: "-0.00010000", fee: "0.00", time: 1_700_000_000),
      "LSWP04" => ledger_entry(type: "receive", asset: "XXBT", amount: "0.00004000",  fee: "0.00", time: 1_700_000_000)
    )

    process

    %w[LSWP03 LSWP04].each do |id|
      trade = @account.entries.find_by(external_id: "kraken_ledger_#{id}", source: "kraken").entryable
      assert trade.internal_movement?, "#{id} must not create or relieve a cost basis"
    end
  end

  # Kraken sweeps into crypto today, but a fiat half must not read as income.
  test "a fiat half of a sweep is labelled as the internal movement it is" do
    set_ledgers(
      "LSWP05" => ledger_entry(type: "receive", asset: "ZUSD", amount: "3.00", fee: "0.00", time: 1_700_000_000)
    )

    process

    entry = @account.entries.find_by(external_id: "kraken_ledger_LSWP05", source: "kraken")
    assert_equal "Transaction", entry.entryable_type
    assert_equal "Sweep In", entry.entryable.investment_activity_label
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
