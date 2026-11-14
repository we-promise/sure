# frozen_string_literal: true

require "test_helper"

class Provider::ConnectionDeclarationTest < ActiveSupport::TestCase
  test "every registered adapter declares its connection" do
    undeclared = Provider::Factory.registered_adapters.reject(&:connection_declaration)

    assert_empty undeclared.map(&:name)
  end

  test "each declaration names a family connection and its accounts association" do
    Provider::Factory.connection_declarations.each do |declaration|
      family_association = Family.reflect_on_association(declaration[:association])
      assert family_association, "Family has no #{declaration[:association]} for #{declaration[:key]}"
      assert_equal declaration[:type], family_association.klass.name

      item_class = declaration[:type].constantize
      assert item_class.reflect_on_association(declaration[:accounts]),
             "#{declaration[:type]} has no #{declaration[:accounts]}"
      if declaration[:linked_accounts]
        assert item_class.reflect_on_association(declaration[:linked_accounts]),
               "#{declaration[:type]} has no #{declaration[:linked_accounts]}"
      end
    end
  end

  test "irregular connections declare their own associations" do
    declarations = Provider::Factory.connection_declarations.index_by { |declaration| declaration[:key] }

    assert_equal :financekit_account_lineages, declarations.fetch("financekit")[:accounts]
    assert_equal :linked_accounts, declarations.fetch("snaptrade")[:linked_accounts]
    assert_not declarations.fetch("brex").key?(:linked_accounts)
  end

  test "an adapter that registers no provider type declares no connection" do
    assert_not Provider::Factory.connection_declarations.any? { |declaration| declaration[:key] == "plaid_eu" }
    assert_equal 1, Provider::Factory.connection_declarations.count { |declaration| declaration[:type] == "PlaidItem" }
  end

  test "connection status providers are the declarations in key order" do
    keys = ProviderConnectionStatus::PROVIDERS.map { |provider| provider[:key] }

    assert_equal Provider::Factory.connection_declarations, ProviderConnectionStatus::PROVIDERS
    assert_equal keys.sort, keys
    assert_equal keys.uniq, keys
  end

  # File order is not key order once a key is a prefix of another followed by a
  # digit ("foo2_adapter.rb" sorts before "foo_adapter.rb"), so the order must
  # come from the keys, not the directory listing.
  test "declarations are sorted by key whatever order the adapter files arrive in" do
    files = Provider::Factory.send(:adapter_files)
    Provider::Factory.stubs(:adapter_files).returns(files.reverse)

    keys = Provider::Factory.connection_declarations.map { |declaration| declaration[:key] }

    assert_equal keys.sort, keys
  end

  test "a provider names itself once, outside its metadata" do
    adapter = Class.new(Provider::Base)

    error = assert_raises(ArgumentError) do
      adapter.declares_connection key: "gocardless", name: "GoCardless", metadata: { name: "Other", kinds: %w[Bank] }
    end
    assert_match "gocardless", error.message
    assert_raises(ArgumentError) { adapter.declares_connection key: "gocardless", name: "GoCardless", metadata: { key: "x" } }
    assert_nil adapter.metadata_declaration
  end

  test "family connections are listed alphabetically by provider" do
    providers = ProviderConnectionStatus.for_family(families(:dylan_family)).map { |connection| connection[:provider] }

    assert_operator providers.index("brex"), :<, providers.index("mercury")
    assert_equal providers.chunk_while { |a, b| a == b }.map(&:first).sort,
                 providers.chunk_while { |a, b| a == b }.map(&:first)
  end

  # The Bank sync page and each provider's panel load items with these queries, which
  # differ per provider and per list: credential filters, select(:id) and preloads.
  ITEM_LIST_QUERIES = {
    "akahu"          => [ ->(i) { i.active.ordered }, ->(i) { i.active.ordered } ],
    "binance"        => [ ->(i) { i.active.ordered }, ->(i) { i.active.ordered } ],
    "brex"           => [ ->(i) { i.active.ordered }, ->(i) { i.active.ordered.includes(:syncs, :brex_accounts) } ],
    "coinbase"       => [ ->(i) { i.ordered }, ->(i) { i.ordered } ],
    "coinspot"       => [ ->(i) { i.active.ordered }, ->(i) { i.active.ordered } ],
    "coinstats"      => [ ->(i) { i.ordered }, ->(i) { i.ordered } ],
    "enable_banking" => [ ->(i) { i.ordered }, ->(i) { i.ordered } ],
    "fio"            => [ ->(i) { i.active.ordered }, ->(i) { i.active.ordered } ],
    "ibkr"           => [ ->(i) { i.ordered.select(:id) }, ->(i) { i.ordered } ],
    "indexa_capital" => [ ->(i) { i.ordered.select(:id) }, ->(i) { i.ordered } ],
    "kraken"         => [ ->(i) { i.active.ordered }, ->(i) { i.active.ordered } ],
    "lunchflow"      => [ ->(i) { i.where.not(api_key: [ nil, "" ]).ordered.select(:id) }, ->(i) { i.ordered } ],
    "mercury"        => [ ->(i) { i.active.ordered }, ->(i) { i.active.ordered.includes(:syncs, :mercury_accounts) } ],
    "monobank"       => [ ->(i) { i.active.ordered }, ->(i) { i.active.ordered } ],
    "onchain_wallet" => [ ->(i) { i.active.ordered }, ->(i) { i.active.ordered } ],
    "questrade"      => [ ->(i) { i.active.ordered.select(:id) }, ->(i) { i.active.ordered } ],
    "redbark"        => [ ->(i) { i.where.not(api_key: [ nil, "" ]).ordered.select(:id) }, ->(i) { i.ordered } ],
    "sharesight"     => [ ->(i) { i.active.ordered }, ->(i) { i.active.ordered } ],
    "simplefin"      => [ ->(i) { i.where.not(access_url: [ nil, "" ]).ordered.select(:id) }, ->(i) { i.ordered } ],
    "snaptrade"      => [ ->(i) { i.ordered }, ->(i) { i.includes(:snaptrade_accounts).ordered } ],
    "sophtron"       => [ ->(i) { i.where.not(user_id: [ nil, "" ], access_key: [ nil, "" ]).ordered.select(:id) }, ->(i) { i.ordered } ],
    "trade_republic" => [ ->(i) { i.active.ordered.includes(:trade_republic_accounts) }, ->(i) { i.active.ordered.includes(:trade_republic_accounts) } ],
    "trading212"     => [ ->(i) { i.ordered }, ->(i) { i.ordered } ],
    "truelayer"      => [ ->(i) { i.active.ordered }, ->(i) { i.active.ordered } ],
    "up"             => [ ->(i) { i.active.ordered }, ->(i) { i.active.ordered } ],
    "wise"           => [ ->(i) { i.active.ordered }, ->(i) { i.active.ordered.includes(:syncs, :wise_accounts) } ]
  }.freeze

  test "each panel provider declares the queries its Bank sync page and panel load items with" do
    family = families(:dylan_family)
    declarations = Provider::Factory.connection_declarations.index_by { |declaration| declaration[:key] }

    assert_equal Settings::ProvidersController::FAMILY_PANEL_KEYS.sort, ITEM_LIST_QUERIES.keys
    ITEM_LIST_QUERIES.each do |key, (page, panel)|
      items = family.public_send(declarations.fetch(key)[:association])
      lists = declarations.fetch(key)[:lists]

      { settings_page: page, settings_panel: panel }.each do |list, query|
        expected = query.call(items)
        actual = lists.fetch(list).call(items)
        assert_equal expected.to_sql, actual.to_sql, "#{key} #{list}"
        assert_equal expected.includes_values, actual.includes_values, "#{key} #{list} preloads"
      end
    end
  end

  test "a list query may be scope names or a lambda, and an unknown list is rejected" do
    adapter = Class.new(Provider::Base)
    adapter.declares_connection(key: "brex", name: "Brex", lists: { settings_page: %i[active ordered] })
    items = families(:dylan_family).brex_items

    assert_equal items.active.ordered.to_sql, adapter.connection_declaration[:lists][:settings_page].call(items).to_sql
    assert_equal items.ordered.to_sql, adapter.connection_declaration[:lists][:settings_panel].call(items).to_sql
    assert_raises(ArgumentError) { adapter.declares_connection(key: "brex", name: "Brex", lists: { settings_pages: %i[ordered] }) }
  end
end
