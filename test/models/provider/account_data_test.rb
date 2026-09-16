# These contracts are pure Ruby. Keep this suite runnable without Rails, a
# database, credentials or network; it also runs in the regular Rails test suite.
require "minitest/autorun"
require_relative "../../../app/models/provider"
require_relative "../../../app/models/provider/account_data"
require_relative "../../../app/models/provider/account_data/definition"
require_relative "../../../app/models/provider/account_data/adapter"
require_relative "../../../app/models/provider/account_data/record"
require_relative "../../../app/models/provider/account_data/page"

class Provider::AccountDataTest < Minitest::Test
  def definition(**overrides)
    Provider::AccountData::Definition.new(**{
      key: "example_eu", source: "example", credential_scope: "connection",
      fields: [ { name: "token", type: "text", secret: true, default: nil } ],
      capabilities: [ "transactions" ]
    }.merge(overrides))
  end

  def transaction(**overrides)
    Ingestion::Record.transaction(**{
      external_id: "legacy_123", name: "Deposit", date: Date.new(2026, 9, 14),
      amount: BigDecimal("-12.340000000000000001"), currency: "USD", pending: false
    }.merge(overrides))
  end

  def test_definition_preserves_source_independently_of_registry_key
    assert_equal "example_eu", definition.key
    assert_equal "example", definition.source
    assert definition.supports?(:transactions)
    refute definition.supports?(:holdings)
  end

  def test_definition_rejects_duplicate_fields_invalid_types_and_secret_defaults
    assert_raises(ArgumentError) { definition(fields: definition.fields * 2) }
    assert_raises(ArgumentError) { definition(fields: [ { name: "token", type: "jsonb", secret: true } ]) }
    assert_raises(ArgumentError) { definition(fields: [ { name: "token", type: "text", secret: true, default: "secret" } ]) }
    assert_raises(ArgumentError) { definition(fields: [ { name: "enabled", type: "boolean", secret: false, default: "false" } ]) }
    assert_raises(ArgumentError) { definition(capabilities: [ "unknown" ]) }
    assert_raises(ArgumentError) { definition(credential_scope: "user_input") }
  end

  def test_definition_does_not_retain_mutable_declaration_strings
    field_name = "token"
    capabilities = [ "transactions" ]
    value = definition(fields: [ { name: field_name, type: "text", secret: true } ], capabilities: capabilities)
    field_name.replace("changed")
    capabilities.first.replace("holdings")

    assert_equal "token", value.fields.first[:name]
    assert value.supports?("transactions")
    assert_raises(FrozenError) { value.fields.first[:name].replace("changed") }
  end

  def test_records_preserve_exact_amount_identity_pending_and_fx_metadata
    value = transaction(metadata: { "example" => { "pending" => false, "fx_from" => "EUR" } })
    assert_equal "legacy_123", value[:external_id]
    assert_equal BigDecimal("-12.340000000000000001"), value[:amount]
    assert_equal false, value[:pending]
    assert_equal "EUR", value[:metadata]["example"]["fx_from"]
    assert_equal Date.new(2026, 9, 14), value[:date]
  end

  def test_missing_or_imprecise_financial_values_are_not_silently_coerced
    [ nil, "", 1.23, "1.23", BigDecimal("NaN"), BigDecimal("Infinity") ].each do |amount|
      assert_raises(ArgumentError) { transaction(amount: amount) }
    end
    assert_raises(ArgumentError) { transaction(currency: nil) }
    assert_raises(ArgumentError) { transaction(pending: "false") }
    assert_raises(ArgumentError) { transaction(date: DateTime.new(2026, 9, 14)) }
    assert_raises(ArgumentError) { transaction(external_id: " ") }
    assert_raises(ArgumentError) { transaction(unrecognized: "field") }
  end

  def test_unknown_balances_remain_absent_and_explicit_zero_is_retained
    value = Ingestion::Record.account(external_id: "1", name: "Bank", currency: "USD")
    refute value.attributes.key?(:balance)
    with_zero = Ingestion::Record.account(external_id: "2", name: "Bank", currency: "USD", balance: BigDecimal("0"))
    assert_equal BigDecimal("0"), with_zero[:balance]
  end

  def test_discovery_may_omit_currency_but_reported_balances_require_it
    inventory = Ingestion::Record.account(external_id: "discovered", name: "New account")
    assert_nil inventory[:currency]
    assert_raises(ArgumentError) do
      Ingestion::Record.account(external_id: "discovered", name: "New account", balance: BigDecimal("0"))
    end
  end

  def test_account_balance_kinds_and_their_date_remain_distinct
    value = Ingestion::Record.account(external_id: "1", name: "Bank", currency: "USD",
      balance: BigDecimal("30"), available_balance: BigDecimal("25"),
      reserved_balance: BigDecimal("5"), cash_balance: nil, balance_date: Date.new(2026, 9, 14))
    assert_equal BigDecimal("25"), value[:available_balance]
    assert_equal BigDecimal("5"), value[:reserved_balance]
    assert_nil value[:cash_balance]
    assert_equal Date.new(2026, 9, 14), value[:balance_date]
    assert_raises(ArgumentError) do
      Ingestion::Record.account(external_id: "1", name: "Bank", currency: "USD", available_balance: 25.0)
    end
  end

  def test_record_metadata_is_copied_recursively_and_inspection_is_redacted
    metadata = { "private" => [ "sensitive description" ] }
    value = transaction(metadata: metadata)
    metadata["private"].first.replace("changed")

    assert_equal "sensitive description", value[:metadata]["private"].first
    assert_raises(FrozenError) { value[:metadata]["private"] << "more" }
    refute_includes value.inspect, "Deposit"
    refute_includes value.inspect, "legacy_123"
  end

  def test_holdings_and_activities_preserve_decimal_quantity_and_security_identity
    holding = Ingestion::Record.holding(
      external_id: "holding_1", currency: "USD", date: Date.new(2026, 9, 14),
      quantity: BigDecimal("0.123456789012345678"), security: { "isin" => "TEST" }
    )
    assert_equal BigDecimal("0.123456789012345678"), holding[:quantity]
    refute holding.attributes.key?(:price)
    activity = Ingestion::Record.activity(
      external_id: "trade_1", currency: "USD", date: Date.new(2026, 9, 14),
      name: "Buy", amount: BigDecimal("10"), activity_type: "buy",
      quantity: BigDecimal("0.5"), price: BigDecimal("20"), security: { "isin" => "TEST" }
    )
    assert_equal "buy", activity[:activity_type]
    assert_equal "TEST", activity[:security]["isin"]
  end

  def test_page_distinguishes_complete_empty_snapshot_from_partial_inventory
    complete = Provider::AccountData::Page.new(records: [], complete: true, mode: "snapshot")
    partial = Provider::AccountData::Page.new(records: [], complete: false, mode: "snapshot", warnings: [ "partial response" ])
    assert complete.complete?
    refute partial.complete?
    assert_nil partial.next_cursor
    assert_equal [ "partial response" ], partial.warnings
  end

  def test_complete_delta_retains_next_sync_checkpoint_without_page_continuation
    page = Provider::AccountData::Page.new(records: [ transaction ], complete: true, checkpoint_cursor: "next-sync")
    assert page.complete?
    assert_equal "next-sync", page.checkpoint_cursor
    assert_nil page.next_cursor
    assert_raises(ArgumentError) { Provider::AccountData::Page.new(records: [], complete: true, next_cursor: "next-page") }
  end

  def test_page_retains_actual_coverage_tombstones_and_continuation_without_authorizing_absence
    page = Provider::AccountData::Page.new(records: [ transaction ], complete: false,
      next_cursor: "opaque-page", removed_ids: [ "legacy_removed" ], coverage: { "through" => Date.new(2026, 9, 14) })
    assert_equal "opaque-page", page.next_cursor
    assert_equal "delta", page.mode
    assert_equal [ "legacy_removed" ], page.removed_ids
    assert_equal Date.new(2026, 9, 14), page.coverage["through"]
    refute page.complete?
    refute_includes page.inspect, "legacy_removed"
    refute_includes page.inspect, "opaque-page"
  end

  def test_page_rejects_untyped_records_mutable_objects_and_ambiguous_completeness
    [ {}, nil, Object.new.freeze ].each do |record|
      assert_raises(ArgumentError) { Provider::AccountData::Page.new(records: [ record ], complete: false) }
    end
    wrapper = Struct.new(:values).new([]).freeze
    assert_raises(ArgumentError) { Provider::AccountData::Page.new(records: [], complete: false, warnings: [ wrapper ]) }
    assert_raises(ArgumentError) { Provider::AccountData::Page.new(records: [], complete: nil) }
    assert_raises(ArgumentError) { Provider::AccountData::Page.new(records: [], complete: false, mode: "unknown") }
    assert_raises(ArgumentError) { Provider::AccountData::Page.new(records: [], complete: false, removed_ids: [ nil ]) }
  end

  def test_page_does_not_retain_mutable_cursor_or_metadata_inputs
    cursor = "private-cursor"
    warnings = [ { "code" => "partial" } ]
    page = Provider::AccountData::Page.new(records: [], complete: false, next_cursor: cursor, warnings: warnings)
    cursor.replace("changed")
    warnings.first["code"].replace("changed")
    assert_equal "private-cursor", page.next_cursor
    assert_equal "partial", page.warnings.first["code"]
    assert_raises(FrozenError) { page.warnings.first["code"].replace("changed") }
  end

  def test_adapter_fails_explicitly_instead_of_reporting_an_empty_success
    contract = definition
    adapter_class = Class.new(Provider::AccountData::Adapter) do
      define_singleton_method(:definition) { contract }
    end
    adapter = adapter_class.new(client: { token: "secret-token" })
    assert_raises(Provider::AccountData::NotImplementedError) { adapter.list_accounts }
    assert_raises(Provider::AccountData::NotImplementedError) { adapter.fetch_transactions(account: "1", window: {}) }
    assert_raises(Provider::AccountData::UnsupportedCapability) { adapter.fetch_holdings(account: "1") }
    refute_includes adapter.inspect, "secret-token"
  end
end
