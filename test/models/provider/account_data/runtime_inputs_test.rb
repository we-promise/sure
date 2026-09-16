require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::RuntimeInputsTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "factory receives only declared account inputs and evidence contains no retained or credential values" do
    with_provider_encryption do
      connection, external, account, link = linked_connection("coinbase")
      external.update!(sensitive_details: { "unrequested_secret" => "private-routing-secret" })
      grant, adapter, context = construct(connection, Provider::AccountData::Coinbase)
      row = context.fetch(:external_accounts).sole

      assert_equal external.id, row.fetch(:id)
      assert_equal external.identity_namespace, row.fetch(:identity_namespace)
      assert_equal account.currency, row.dig(:linked_account, :currency)
      assert_equal account.accountable_id, row.dig(:linked_account, :accountable_id)
      assert_equal link.id, row.dig(:linked_account, :account_provider_id)
      assert_equal link.lock_version, row.dig(:linked_account, :account_provider_revision)
      refute row.key?(:sensitive_details)
      assert_same grant, adapter.request_grant
      proof = grant.snapshot.fetch("runtime_inputs")
      assert_equal [ external.id ], proof.fetch("external_accounts").keys
      assert_equal "connection", proof.dig("external_accounts", external.id, "identity_namespace")
      serialized = JSON.generate(grant.snapshot)
      refute_includes serialized, "private-routing-secret"
      refute_includes serialized, "private-provider-token"
      assert grant.verify!
    end
  end

  test "cached linked currency cannot be validated by a later fresh page binding" do
    with_provider_encryption do
      connection, external, account, link = linked_connection("coinbase")
      grant, = construct(connection, Provider::AccountData::Coinbase)
      account.update!(currency: "EUR")
      Account::SourcePolicy.select!(account: account, account_provider: link, resource: "balances")
      fresh = Provider::AccountData::GenerationAccounts.new(connection, resource: "balances").capture_one(external)
      assert_equal "EUR", fresh.fetch("account_currency")
      assert_raises(Provider::AccountData::StaleWriter) { grant.capture_request { flunk "Stale currency reached HTTP" } }
    end
  end

  test "delegated account identity and same UUID link revision changes reject the cached adapter" do
    with_provider_encryption do
      connection, _external, account, link = linked_connection("coinbase")
      grant, = construct(connection, Provider::AccountData::Coinbase)
      account.update_columns(accountable_type: "Investment", accountable_id: accounts(:investment).accountable_id)
      assert_raises(Provider::AccountData::StaleWriter) { grant.verify! }
      fresh, = construct(connection, Provider::AccountData::Coinbase)
      link.update!(updated_at: 1.second.from_now)
      assert_raises(Provider::AccountData::StaleWriter) { fresh.verify! }
    end
  end

  test "unlink and relink to another financial account cannot reuse the construction context" do
    with_provider_encryption do
      connection, external, _account, link = linked_connection("trade_republic")
      grant, = construct(connection, Provider::AccountData::TradeRepublic)
      link.destroy!
      AccountProvider.create!(account: accounts(:credit_card), external_account: external)
      assert_raises(Provider::AccountData::StaleWriter) { grant.capture_request { flunk } }
    end
  end

  test "routing edits during a request retain evidence but prevent publication" do
    with_provider_encryption do
      connection, external, = linked_connection("coinstats")
      external.update!(sensitive_details: { "source_descriptor" => { "wallet_address" => "private-wallet-a" } })
      grant, = construct(connection, Provider::AccountData::Coinstats)
      page, capture = grant.capture_request do
        external.update!(sensitive_details: { "source_descriptor" => { "wallet_address" => "private-wallet-b" } })
        empty_page
      end
      captured = Provider::AccountData::RequestGrant.attach(page, capture)
      refute_includes JSON.generate(captured.evidence), "private-wallet"
      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: captured.evidence.fetch("request_grant"), require_runtime_inputs: true)
      end
    end
  end

  test "retained portfolio updates and discovery of an unlinked account leave the frozen baseline intact" do
    with_provider_encryption do
      connection, external, = linked_connection("binance")
      external.update!(metadata: { "portfolio_sources" => { "spot" => { "quantity" => "1.25" } } })
      grant, _adapter, context = construct(connection, Provider::AccountData::Binance)
      original = grant.snapshot.fetch("runtime_inputs")
      external.update!(current_balance: 99, name: "Updated inventory", metadata: { "portfolio_sources" => { "spot" => { "quantity" => "2.75" } } })
      create_external_account(connection, external_id: "new-unlinked")

      assert grant.verify!
      assert_equal "1.25", context.fetch(:external_accounts).sole.dig(:metadata, :portfolio_sources, "spot", "quantity")
      assert_equal original, grant.snapshot.fetch("runtime_inputs")
      _page, capture = grant.capture_request { empty_page }
      assert Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: capture, require_runtime_inputs: true)
    end
  end

  test "a newly linked cash account changes the cached selection before the next request" do
    with_provider_encryption do
      connection, = linked_connection("trade_republic")
      grant, = construct(connection, Provider::AccountData::TradeRepublic)
      external = create_external_account(connection, external_id: "cash:new")
      AccountProvider.create!(account: accounts(:credit_card), external_account: external)
      assert_raises(Provider::AccountData::StaleWriter) { grant.capture_request { flunk } }
    end
  end

  test "reviewed selected asset inventory rejects even a new unlinked source" do
    with_provider_encryption do
      connection, = linked_connection("coinstats")
      grant, = construct(connection, Provider::AccountData::Coinstats)
      create_external_account(connection, external_id: "new-selected-wallet")
      assert_raises(Provider::AccountData::StaleWriter) { grant.verify! }
    end
  end

  test "same upstream ID in different namespaces cannot silently select a cached sibling" do
    with_provider_encryption do
      connection, external, = linked_connection("coinbase")
      create_external_account(connection, external_id: external.external_id, identity_namespace: "institution:other")
      Provider::AccountData::Registry.stubs(:fetch).with("coinbase").returns(Provider::AccountData::Coinbase)
      Provider::AccountData::Coinbase.expects(:build).never
      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::Registry.build(connection, observed_at: Time.current)
      end
    end
  end

  test "runtime evidence cannot move between connections or families" do
    with_provider_encryption do
      connection = create_provider_connection
      grant, = construct(connection, Provider::AccountData::Up)
      [ create_provider_connection, create_provider_connection(family: families(:empty)) ].each do |other|
        assert_raises(Provider::AccountData::StaleWriter) do
          Provider::AccountData::RuntimeInputs.restore(other, grant.snapshot.fetch("runtime_inputs"))
        end
      end
    end
  end

  test "family preferences and connection settings stay tied to their construction values" do
    with_provider_encryption do
      connection = create_provider_connection
      grant, = construct(connection, Provider::AccountData::Up)
      connection.family.update!(currency: "EUR")
      assert_raises(Provider::AccountData::StaleWriter) { grant.capture_request { flunk } }
      fresh, = construct(connection, Provider::AccountData::Up)
      connection.update!(settings: { "provider_option" => "replacement" })
      assert_raises(Provider::AccountData::StaleWriter) { fresh.verify! }
    end
  end

  test "application credential replacement changes only a keyed proof and cannot publish an older response" do
    with_provider_encryption do
      connection = create_provider_connection(provider_key: "plaid", region: "us", environment: "production")
      Provider::AccountData::ApplicationCredentials.stubs(:build).returns(client_id: "private-app-id", secret: "private-app-secret-a")
      grant, = construct(connection, Provider::AccountData::Plaid)
      _page, capture = grant.capture_request do
        Provider::AccountData::ApplicationCredentials.stubs(:build).returns(client_id: "private-app-id", secret: "private-app-secret-b")
        empty_page
      end
      refute_includes JSON.generate(capture), "private-app"
      error = assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: capture, require_runtime_inputs: true)
      end
      refute_includes error.message, "private-app"
    end
  end

  test "fallback credentials and fingerprint key rotation invalidate old captured inputs" do
    with_provider_encryption do
      connection = create_provider_connection(provider_key: "indexa_capital")
      Provider::AccountData::ApplicationCredentials.stubs(:fallback).returns(api_token: "private-fallback-a")
      grant, = construct(connection, Provider::AccountData::IndexaCapital)
      Provider::AccountData::ApplicationCredentials.stubs(:fallback).returns(api_token: "private-fallback-b")
      assert_raises(Provider::AccountData::StaleWriter) { grant.capture_request { flunk } }
      refute_includes JSON.generate(grant.snapshot), "private-fallback"
      fresh, = construct(connection, Provider::AccountData::IndexaCapital)
      Rails.application.key_generator.stubs(:generate_key).with("provider-runtime-inputs/v1", 32).returns("a-different-purpose-key")
      assert_raises(Provider::AccountData::StaleWriter) { fresh.verify! }
    end
  end

  test "regexp configuration retains its type rather than colliding with an ordinary hash" do
    with_provider_encryption do
      connection = create_provider_connection(provider_key: "simplefin")
      Ingestion::BalancePolicies::Simplefin::Snapshot.stubs(:build).returns({})
      configuration = Rails.configuration.x.simplefin
      original = configuration.money_market_patterns
      configuration.money_market_patterns = [ /cash/i ]
      grant, = construct(connection, Provider::AccountData::Simplefin)
      configuration.money_market_patterns = [ { "regexp_source" => "cash", "regexp_options" => Regexp::IGNORECASE } ]
      assert_raises(Provider::AccountData::StaleWriter) { grant.verify! }
    ensure
      configuration.money_market_patterns = original if configuration
    end
  end

  test "SimpleFIN history is captured once while policy settings and UUID identity remain live" do
    with_provider_encryption do
      connection, external, account, = linked_connection("simplefin")
      policy = { "enabled" => true, "settings" => Ingestion::BalancePolicies::Simplefin::Snapshot::DEFAULTS }
      Ingestion::BalancePolicies::Simplefin::Snapshot.stubs(:configuration).returns(policy)
      captured = { "schema_version" => 1, "enabled" => true, "account_id" => account.id,
        "external_account_id" => external.id, "identity_namespace" => external.identity_namespace, "entry_metrics" => { "tx_count" => 7 } }
      Ingestion::BalancePolicies::Simplefin::Snapshot.expects(:build).once.with do |arguments|
        arguments[:key_by] == :id && arguments[:external_accounts].map(&:id) == [ external.id ] && arguments[:configuration] == policy
      end.returns(external.id => captured)
      grant, _adapter, context = construct(connection, Provider::AccountData::Simplefin)
      external.update!(sensitive_details: { "balance_policy_state" => { "simplefin" => { "value" => "credit", "expires_at" => 1.day.from_now.iso8601 } } })
      assert grant.verify!
      assert grant.verify!
      assert_equal 7, context.dig(:simplefin_balance_classification, :accounts, external.id, "entry_metrics", "tx_count")
      Ingestion::BalancePolicies::Simplefin::Snapshot.stubs(:configuration).returns(policy.deep_merge("settings" => { "min_txns" => 25 }))
      assert_raises(Provider::AccountData::StaleWriter) { grant.verify! }
    end
  end

  test "a bounded account inventory fails before factory or credential construction" do
    with_provider_encryption do
      connection, = linked_connection("coinbase")
      owner = Provider::AccountData::RuntimeInputs
      limit = owner::MAX_ACCOUNTS
      owner.send(:remove_const, :MAX_ACCOUNTS)
      owner.const_set(:MAX_ACCOUNTS, 0)
      Provider::AccountData::Registry.stubs(:fetch).with("coinbase").returns(Provider::AccountData::Coinbase)
      Provider::AccountData::Coinbase.expects(:build).never
      Provider::AccountData::CredentialStore.expects(:new).never
      assert_raises(Provider::AccountData::IncompletePage) { Provider::AccountData::Registry.build(connection, observed_at: Time.current) }
    ensure
      if owner && limit
        owner.send(:remove_const, :MAX_ACCOUNTS)
        owner.const_set(:MAX_ACCOUNTS, limit)
      end
    end
  end

  test "undeclared or overlapping account input paths cannot reach a factory" do
    with_provider_encryption do
      connection = create_provider_connection(provider_key: "coinbase")
      [ nil, { mutable: [ "metadata" ], frozen: [ "metadata.retained" ], inventory: "linked" },
        { mutable: [ "credentials.access_token" ], frozen: [], inventory: "linked" } ].each do |declaration|
        adapter = Class.new(Provider::AccountData::Coinbase)
        adapter.define_singleton_method(:external_account_inputs) { declaration }
        assert_raises(ArgumentError) do
          Provider::AccountData::RuntimeInputs.new(connection, adapter: adapter, observed_at: Time.current)
        end
      end
    end
  end

  test "a page without runtime input proof requires a reviewed restart in production" do
    with_provider_encryption do
      connection = create_provider_connection
      legacy = Provider::AccountData::RequestGrant.new(connection).capture!
      _page, capture = legacy.capture_request { empty_page }
      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: capture, require_runtime_inputs: true)
      end
    end
  end

  test "passing a constructed adapter into Syncer preserves its original stale input check" do
    with_provider_encryption do
      connection, _external, account, = linked_connection("coinbase")
      _grant, adapter, = construct(connection, Provider::AccountData::Coinbase)
      account.update!(currency: "EUR")
      adapter.expects(:list_accounts).never
      sync = connection.syncs.create!
      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(sync)
      end
      assert_empty connection.ingestion_batches
    end
  end

  test "a caller cannot replace the grant bound by Registry with a new unscoped grant" do
    with_provider_encryption do
      connection = create_provider_connection
      _original, adapter, = construct(connection, Provider::AccountData::Up)
      replacement = Provider::AccountData::RequestGrant.new(connection).capture!
      adapter.expects(:list_accounts).never
      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::Syncer.new(connection, adapter: adapter, request_grant: replacement).perform_sync(connection.syncs.create!)
      end
      assert_equal 0, connection.reload.writer_epoch
    end
  end

  private
    def linked_connection(provider_key)
      connection = create_provider_connection(provider_key: provider_key)
      external = create_external_account(connection, external_id: "wallet")
      account = accounts(:depository)
      link = AccountProvider.create!(account: account, external_account: external)
      [ connection, external, account, link ]
    end

    def construct(connection, factory)
      context = nil
      adapter = Provider::AccountData::Adapter.new(client: nil)
      Provider::AccountData::Registry.stubs(:fetch).with(connection.provider_key).returns(factory)
      factory.expects(:build).with do |arguments|
        context = arguments.fetch(:context)
        true
      end.returns(adapter)
      grant = Provider::AccountData::RequestGrant.new(connection)
      built = Provider::AccountData::Registry.build(connection, observed_at: Time.utc(2026, 9, 15), request_grant: grant)
      [ grant, built, context ]
    end

    def empty_page
      Provider::AccountData::Page.new(records: [], complete: true)
    end
end
