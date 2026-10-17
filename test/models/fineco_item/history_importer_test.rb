require "test_helper"

class FinecoItem::HistoryImporterTest < ActiveSupport::TestCase
  setup do
    Current.reset
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Provider::Fineco.stubs(:verified_identity_contract?).returns(true)
    Account.any_instance.stubs(:sync_later).returns(nil)
    @family = families(:dylan_family)
    @owner = users(:family_admin)
    @item = FinecoItem.new(
      family: @family,
      owner: @owner,
      gsessionid: "synthetic-session",
      account_index: "2",
      dossier_index: "11",
      bank_account_number: "SYNTHETIC-ACCOUNT",
      dossier_identity: Digest::SHA256.hexdigest("synthetic-dossier"),
      captured_at: Time.current
    )
    @item.import_portfolio_snapshot!(payload: snapshot_payload, captured_at: Time.current)
    @provider_account = @item.fineco_account
    @account = @provider_account.usable_account
    assert_nil @provider_account.history_ledger
  end

  teardown { Current.reset }

  test "imports cash-neutral EUR trades, preserves locked securities, and encrypts coverage" do
    holding = @account.holdings.sole
    locked_security = Security.create!(ticker: "USER-LOCKED", exchange_operating_mic: "XETR", name: "User selection", offline: true)
    holding.update!(security: locked_security, security_locked: true)
    assert_nil raw_history_ledger
    prior_balance = @account.balance
    prior_cash = @account.cash_balance
    activity = normalized([ row("currency" => "GBP", "price" => "100", "exchange" => "1.2", "equivalentValue" => "360") ]).activities.sole
    sync_calls = 0
    Account.any_instance.stubs(:sync_later) { sync_calls += 1 }

    imported = FinecoItem::HistoryImporter.new(@item).import(
      normalized: normalized([ row("currency" => "GBP", "price" => "100", "exchange" => "1.2", "equivalentValue" => "360") ]),
      coverage_start: Date.new(2026, 10, 17),
      coverage_end: Date.new(2026, 10, 19)
    )

    assert_equal 1, imported
    assert_equal 0, sync_calls, "account synchronization must wait for the surrounding test transaction to commit"
    entry = @account.entries.find_by!(external_id: activity.external_id)
    trade = entry.entryable
    assert_equal locked_security.id, trade.security_id
    assert_equal BigDecimal("3"), trade.qty
    assert_equal BigDecimal("120"), trade.price
    assert_equal BigDecimal("360"), entry.amount
    assert_equal "EUR", entry.currency
    assert_equal BigDecimal("100"), @account.reload.balance
    assert_equal BigDecimal("0"), @account.cash_balance
    assert_equal prior_balance, @account.balance
    assert_equal prior_cash, @account.cash_balance
    assert trade.fineco_history_entry?(entry)
    refute trade.affects_cash_balance?(entry)
    assert_equal "GBP", trade.extra.dig("fineco", "original_currency")
    assert_equal "100.0", trade.extra.dig("fineco", "original_price")
    assert_equal "1.2", trade.extra.dig("fineco", "exchange")
    assert_equal "2026-10-19", trade.extra.dig("fineco", "value_date")
    assert_equal 1, @provider_account.reload.history_ledger.dig("days", "2026-10-17", activity.fingerprint)
    assert_not_nil @provider_account.history_synced_at
    raw_ledger = raw_history_ledger
    refute_includes raw_ledger, "coverage_from"
    refute_includes raw_ledger, activity.fingerprint
  end

  test "appends identical multiplicity and remains idempotent on replay" do
    rows = [ row, row ]
    result = normalized(rows)

    assert_equal [ 1, 2 ], result.activities.map(&:occurrence)
    assert_equal 2, import(result)
    assert_equal 0, import(normalized(rows))
    assert_equal 2, @account.entries.where(source: "fineco").count

    assert_equal 1, import(normalized([ row, row, row ]))
    assert_equal 3, @account.entries.where(source: "fineco").count
    assert_equal 3, @provider_account.reload.history_ledger.dig("days", "2026-10-17", result.activities.first.fingerprint)
  end

  test "rolls back corrected historical rows without deleting or rekeying saved entries" do
    first = normalized([ row ])
    assert_equal 1, import(first)
    entry = @account.entries.find_by!(external_id: first.activities.sole.external_id)
    old_ledger = @provider_account.reload.history_ledger

    error = assert_raises(FinecoItem::PortfolioImportError) do
      import(normalized([ row("amount" => "4", "equivalentValue" => "400") ]))
    end

    assert_equal "history_changed", error.code
    assert_equal [ entry.id ], @account.entries.where(source: "fineco").ids
    assert_equal old_ledger, @provider_account.reload.history_ledger
  end

  test "keeps a user-protected matching trade unchanged" do
    activity = normalized([ row ]).activities.sole
    security = @account.holdings.sole.security
    entry = @account.entries.create!(
      name: "User-edited history",
      date: Date.new(2026, 10, 1),
      amount: 777,
      currency: "EUR",
      source: "fineco",
      external_id: activity.external_id,
      user_modified: true,
      entryable: Trade.new(security: security, qty: 9, price: 77, currency: "EUR", investment_activity_label: "Buy")
    )

    assert_equal 0, import(normalized([ row ]))

    entry.reload
    assert_equal "User-edited history", entry.name
    assert_equal Date.new(2026, 10, 1), entry.date
    assert_equal BigDecimal("777"), entry.amount
    assert_equal BigDecimal("9"), entry.entryable.qty
  end

  test "uses an offline ISIN security when a closed instrument has no provider holding" do
    bond = row("isin" => "US0000000010", "name" => "Closed bond", "currency" => "GBP")
    assert_equal 1, import(normalized([ bond ]))

    security = Security.find_by!(ticker: "US0000000010", exchange_operating_mic: nil)
    assert security.offline?
    assert_equal "fineco_isin", security.offline_reason
    assert_nil security.price_provider
  end

  test "records an empty completed window without scheduling account synchronization" do
    Account.any_instance.expects(:sync_later).never

    assert_equal 0, import(normalized([]), from: Date.new(2026, 10, 17), to: Date.new(2026, 10, 19))
    ledger = @provider_account.reload.history_ledger
    assert_equal({ "2026-10-17" => {}, "2026-10-18" => {}, "2026-10-19" => {} }, ledger.fetch("days"))
    assert_not_nil @provider_account.history_synced_at
  end

  private

    def import(result, from: Date.new(2026, 10, 17), to: Date.new(2026, 10, 19))
      FinecoItem::HistoryImporter.new(@item).import(normalized: result, coverage_start: from, coverage_end: to)
    end

    def normalized(rows)
      FinecoItem::HistoryNormalizer.new(rows: rows, bank_scope: "synthetic-bank-scope").normalize
    end

    def row(overrides = {})
      {
        "type" => "ORDER",
        "transactionDate" => "2026-10-17T12:34:56",
        "valueDate" => "2026-10-19T00:00:00",
        "description" => "Synthetic activity",
        "name" => "Synthetic activity",
        "isin" => "US0000000002",
        "sign" => "A",
        "amount" => "3",
        "currency" => "EUR",
        "price" => "100",
        "exchange" => "1",
        "equivalentValue" => "300"
      }.merge(overrides)
    end

    def raw_history_ledger
      ActiveRecord::Base.connection.select_value(
        "SELECT history_ledger::text FROM fineco_accounts WHERE id = #{ActiveRecord::Base.connection.quote(@provider_account.id)}"
      )
    end

    def snapshot_payload
      currencies = [ "EUR" ]
      types = [ "etf" ]
      position = {
        "instrId" => "US0000000002",
        "venueSystem" => "XETRA",
        "symbol" => "SYNTH",
        "description" => "Synthetic fund",
        "type" => "etf",
        "currencyCd" => "EUR",
        "qty" => "2",
        "avgPrice" => "45",
        "marketPrice" => "50",
        "bookValue" => "90",
        "marketValue" => "100",
        "profitLoss" => "10",
        "accrual" => "0.5",
        "ongoingAccrual" => "0.25"
      }
      summary = {
        "currencyCd" => "EUR",
        "bookValue" => "90",
        "marketValue" => "100",
        "profitLoss" => "10",
        "profitLossPerc" => "11.11",
        "accrual" => "0.5"
      }
      {
        "info" => { "dossier" => { "blocked" => false } },
        "filters" => {
          "currencies" => { "total" => currencies, "show" => currencies },
          "instrumentTypes" => { "total" => types, "show" => types }
        },
        "positions" => { "show" => [ position ] },
        "summary" => { "show" => summary, "total" => summary }
      }
    end
end
