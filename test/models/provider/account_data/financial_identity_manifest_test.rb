require "test_helper"

class Provider::AccountData::FinancialIdentityManifestTest < ActiveSupport::TestCase
  Manifest = Provider::AccountData::FinancialIdentityManifest
  LEGACY_ID = "11111111-2222-4333-8444-555555555555".freeze

  test "every copied provider has a reviewed financial identity convention including the specialized Plaid path" do
    assert_equal Provider::AccountData::MigrationManifest.provider_keys.sort, Manifest::PROVIDER_KEYS
    assert_equal Manifest::PROVIDER_KEYS, Manifest::ARCHIVE_COLUMNS.keys.sort
    assert Manifest.for("plaid").specialized?
    assert_raises(ArgumentError) { Manifest.for("plaid_eu") }
    assert_raises(ArgumentError) { Manifest.for("unreviewed") }
    Manifest::PROVIDER_KEYS.each do |key|
      manifest = Manifest.for(key)
      assert_equal key, manifest.source
      assert_equal manifest.source, Provider::AccountData::Registry.declared_adapter(key).definition.source
      assert_empty manifest.archive_columns - manifest.legacy_manifest.dispositions(:account).fetch(:payloads)
    end
  end

  test "reviewed IDs classify the actual ledger type and stream without parsing financial content" do
    cases = [
      [ "akahu", "akahu_opaque", "Transaction", "transaction" ], [ "brex", "brex_opaque", "Transaction", "transaction" ],
      [ "enable_banking", "enable_banking_content_#{'a' * 32}", "Transaction", "transaction" ],
      [ "lunchflow", "lunchflow_pending_#{'b' * 32}", "Transaction", "transaction" ],
      [ "mercury", "mercury_opaque", "Transaction", "transaction" ], [ "monobank", "monobank_opaque", "Transaction", "transaction" ],
      [ "redbark", "redbark_opaque", "Transaction", "transaction" ], [ "simplefin", "simplefin_opaque", "Transaction", "transaction" ],
      [ "sophtron", "sophtron_opaque", "Transaction", "transaction" ], [ "up", "up_pending_#{'c' * 32}", "Transaction", "transaction" ],
      [ "wise", "wise_statement_#{'d' * 24}_fee", "Transaction", "transaction" ],
      [ "binance", "binance_spot_ETHBTC_123", "Trade", "activity" ], [ "binance", "binance_futures_BTCUSDT_456", "Trade", "activity" ],
      [ "binance", "binance_p2p_123", "Trade", "activity" ], [ "binance", "binance_p2p_123_funding", "Transaction", "activity" ],
      [ "coinbase", "coinbase_txn_opaque", "Trade", "activity" ], [ "coinbase", "coinbase_buy_legacy", "Trade", "activity" ],
      [ "coinstats", "coinstats_opaque", "Trade", "activity" ], [ "coinstats", "coinstats_opaque", "Transaction", "activity" ],
      [ "ibkr", "ibkr_trade_123", "Trade", "activity" ], [ "ibkr", "ibkr_cash_456", "Transaction", "activity" ],
      [ "ibkr", "ibkr_trade_fee_123", "Transaction", "activity" ], [ "indexa_capital", "raw-provider-ID", "Trade", "activity" ],
      [ "indexa_capital", "another-ID", "Transaction", "activity" ], [ "kraken", "kraken_trade_opaque", "Trade", "activity" ],
      [ "kraken", "kraken_ledger_opaque", "Transaction", "transaction" ],
      [ "onchain_wallet", "onchain_#{LEGACY_ID}_0xHash_log_2", "Trade", "activity" ],
      [ "questrade", "questrade_trade_#{'e' * 24}", "Trade", "activity" ], [ "questrade", "questrade_journal_#{'e' * 24}", "Trade", "activity" ],
      [ "questrade", "questrade_fee_#{'e' * 24}", "Transaction", "activity" ], [ "questrade", "questrade_cash_#{'e' * 24}", "Transaction", "activity" ],
      [ "snaptrade", "provider-ID", "Trade", "activity" ], [ "snaptrade", "provider-cash-ID", "Transaction", "activity" ],
      [ "trade_republic", "trade_republic_event_opaque", "Trade", "activity" ], [ "trade_republic", "trade_republic_event_opaque", "Transaction", "activity" ],
      [ "trading212", "trading212_order_123", "Trade", "activity" ], [ "trading212", "trading212_dividend_456", "Transaction", "activity" ],
      [ "trading212", "trading212_transaction_789", "Transaction", "activity" ]
    ]
    cases.each do |provider, id, type, kind|
      rule = Manifest.for(provider).rule_for(id, legacy_account_id: LEGACY_ID)
      assert rule, "#{provider} must retain its reviewed ID form"
      assert_equal kind, rule.kind
      assert_includes rule.entryable_types, type
    end
    assert_equal Manifest::PROVIDER_KEYS - [ "plaid" ], cases.map(&:first).uniq.sort
  end

  test "prefix matching does not erase financial type or wallet account identity conflicts" do
    refute_includes Manifest.for("coinbase").rule_for("coinbase_buy_id", legacy_account_id: LEGACY_ID).entryable_types, "Transaction"
    refute_includes Manifest.for("ibkr").rule_for("ibkr_trade_fee_id", legacy_account_id: LEGACY_ID).entryable_types, "Trade"
    assert_nil Manifest.for("onchain_wallet").rule_for("onchain_another-account_hash", legacy_account_id: LEGACY_ID)
    assert_nil Manifest.for("up").rule_for("up_", legacy_account_id: LEGACY_ID)
    assert_nil Manifest.for("wise").rule_for("wise_unknown_kind_id", legacy_account_id: LEGACY_ID)
    assert_nil Manifest.for("questrade").rule_for("questrade_trade_changed", legacy_account_id: LEGACY_ID)
  end

  test "persisted collision suffixes are recognized as requiring provenance rather than assigned occurrences" do
    base = "lunchflow_pending_#{'a' * 32}"
    assert_equal base, Manifest.for("lunchflow").occurrence_base(base)
    assert_equal base, Manifest.for("lunchflow").occurrence_base("#{base}_17")
    assert_nil Manifest.for("up").occurrence_base("up_pending_#{'b' * 32}")
    assert_empty Manifest.for("indexa_capital").candidate_prefixes
    assert_empty Manifest.for("snaptrade").candidate_prefixes
  end
end
