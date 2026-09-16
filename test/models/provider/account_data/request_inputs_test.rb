require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::RequestInputsTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "one request pins exact UUID namespace typed Record and immutable selected inputs without disclosing routing" do
    with_source do |connection, external, sync, grant, inputs|
      original_window = window(sync)
      original_cursor = "private-continuation"
      admitted, capture = admit(grant, inputs, sync, window: original_window, cursor: original_cursor)
      assert_equal external.id, admitted[:record][:metadata]["runtime_external_account_id"]
      assert_equal "institution:one", admitted[:evidence].dig("scope", "identity_namespace")
      assert admitted[:window].frozen?
      assert admitted[:cursor].frozen?
      assert_raises(FrozenError) { admitted[:window]["start"] = "changed" }
      serialized = JSON.generate(admitted[:evidence])
      %w[private-api-route private-continuation Secret].each { |secret| refute_includes serialized, secret }
      batch = batch_for(connection, external, sync, admitted)
      assert verify(connection, sync, inputs, batch, admitted, capture)
    end
  end

  test "a request-local routing correction during HTTP rejects publication despite an unchanged construction grant" do
    with_source do |connection, external, sync, grant, inputs|
      admitted, capture = admit(grant, inputs, sync) do
        external.update!(sensitive_details: { "api_account_id" => "corrected-api-route" })
      end
      assert Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: capture, scope_sync: sync)
      batch = batch_for(connection, external, sync, admitted)
      assert_raises(Provider::AccountData::StaleWriter) { verify(connection, sync, inputs, batch, admitted, capture) }
      assert batch.reload.captured?
    end
  end

  test "currency account kind and policy metadata from the canonical Record are live per request" do
    [ { currency: "EUR" }, { account_type: "credit" }, { metadata: { "account_kind" => "card", "policy" => "changed" } } ].each do |change|
      with_source do |connection, external, sync, grant, inputs|
        admitted, capture = admit(grant, inputs, sync) { external.update!(change) }
        batch = batch_for(connection, external, sync, admitted)
        assert_raises(Provider::AccountData::StaleWriter) { verify(connection, sync, inputs, batch, admitted, capture) }
      end
    end
  end

  test "fresh routing present at admission is the exact Record supplied to HTTP" do
    with_source do |_connection, external, sync, grant, inputs|
      external.update!(sensitive_details: { "api_account_id" => "latest-before-admission" })
      admitted, = admit(grant, inputs, sync)
      assert_equal "latest-before-admission", admitted[:record][:sensitive_details]["api_account_id"]
    end
  end

  test "changing a selected window dependency before admission never silently chooses another window" do
    %i[connection external sync].each do |target|
      with_source do |connection, external, sync, grant, inputs|
        selected = inputs.configuration
        case target
        when :connection then ProviderConnection.find(connection.id).update!(sync_start_date: Date.current - 180)
        when :external then ExternalAccount.find(external.id).update!(sync_start_date: Date.current - 180)
        when :sync then Sync.find(sync.id).update!(window_start_date: Date.current - 180)
        end
        assert_raises(Provider::AccountData::StaleWriter) do
          admit(grant, inputs, sync, configuration: selected) { flunk "Changed selection reached HTTP" }
        end
      end
    end
  end

  test "a date window correction during HTTP preserves evidence and rejects publication" do
    with_source do |connection, external, sync, grant, inputs|
      admitted, capture = admit(grant, inputs, sync) { Sync.find(sync.id).update!(window_end_date: Date.yesterday) }
      batch = batch_for(connection, external, sync, admitted)
      assert_raises(Provider::AccountData::StaleWriter) { verify(connection, sync, inputs, batch, admitted, capture) }
      assert batch.reload.captured?
    end
  end

  test "a selected cursor and full checkpoint state cannot be replaced before HTTP or publication" do
    with_source do |connection, external, sync, grant, inputs|
      checkpoint = connection.provider_sync_checkpoints.create!(external_account: external, stream: "balances",
        scope_key: "account:#{external.id}", cursor: "cursor-one")
      selected = inputs.checkpoint_fingerprint(checkpoint)
      ProviderSyncCheckpoint.find(checkpoint.id).update_columns(cursor: "cursor-two")
      assert_raises(Provider::AccountData::StaleWriter) do
        admit(grant, inputs, sync, checkpoint: selected, cursor: "cursor-one") { flunk }
      end
      checkpoint.reload
      admitted, capture = admit(grant, inputs, sync, checkpoint: inputs.checkpoint_fingerprint(checkpoint), cursor: "cursor-two") do
        ProviderSyncCheckpoint.find(checkpoint.id).update_columns(state: { "policy" => "changed-without-revision" })
      end
      batch = batch_for(connection, external, sync, admitted)
      assert_raises(Provider::AccountData::StaleWriter) { verify(connection, sync, inputs, batch, admitted, capture) }
    end
  end

  test "a newly inserted checkpoint invalidates a request that selected the absent default" do
    with_source do |connection, external, sync, grant, inputs|
      admitted, capture = admit(grant, inputs, sync) do
        connection.provider_sync_checkpoints.create!(external_account: external, stream: "balances", scope_key: "account:#{external.id}", cursor: "new")
      end
      batch = batch_for(connection, external, sync, admitted)
      assert_raises(Provider::AccountData::StaleWriter) { verify(connection, sync, inputs, batch, admitted, capture) }
    end
  end

  test "page-local cache and checkpoint progress can advance without replacing the selected stream configuration" do
    with_source do |connection, external, sync, grant, inputs|
      configuration = inputs.configuration
      admitted, capture = admit(grant, inputs, sync, configuration: configuration)
      batch = batch_for(connection, external, sync, admitted)
      assert verify(connection, sync, inputs, batch, admitted, capture)
      external.update!(name: "Expected inventory refresh", current_balance: BigDecimal("52"))
      checkpoint = connection.provider_sync_checkpoints.create!(external_account: external, stream: "balances",
        scope_key: "account:#{external.id}", cursor: "next-owned-page")
      next_page, next_capture = admit(grant, inputs, sync, configuration: configuration, checkpoint: inputs.checkpoint_fingerprint(checkpoint),
        cursor: "next-owned-page", request_key: "next-page", window: window(sync).merge("start" => 14.days.ago.utc.iso8601))
      assert_equal BigDecimal("52"), next_page[:record][:balance]
      refute_equal admitted[:evidence]["window"], next_page[:evidence]["window"]
      next_batch = batch_for(connection, external, sync, next_page)
      assert verify(connection, sync, inputs, next_batch, next_page, next_capture)
    end
  end

  test "missing proof and another request or namespace cannot borrow captured inputs" do
    with_source do |connection, external, sync, grant, inputs|
      admitted, capture = admit(grant, inputs, sync)
      batch = batch_for(connection, external, sync, admitted)
      [ nil, admitted[:evidence].deep_dup.tap { |value| value["scope"]["identity_namespace"] = "connection" },
        admitted[:evidence].deep_dup.tap { |value| value["scope"]["request_key"] = "other-page" } ].each do |evidence|
        assert_raises(Provider::AccountData::StaleWriter) { verify(connection, sync, inputs, batch, admitted.merge(evidence: evidence), capture) }
      end
      foreign = create_provider_connection(family: families(:empty))
      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::RequestInputs.new(connection: foreign, sync: sync, stream: "balances", external_account: external, record_builder: ->(_) { flunk })
      end
      assert_raises(Provider::AccountData::StaleWriter) { grant.capture_request(scope_sync: connection.syncs.create!) { flunk } }
    end
  end

  test "request proof byte bounds apply to the exact canonical input before HTTP" do
    with_source do |_connection, external, sync, grant, inputs|
      external.update!(metadata: { "large_input" => "x" * 2_048 })
      owner = Provider::AccountData::RuntimeInputs
      limit = owner::MAX_INPUT_BYTES
      owner.send(:remove_const, :MAX_INPUT_BYTES)
      owner.const_set(:MAX_INPUT_BYTES, 1_024)
      assert_raises(Provider::AccountData::IncompletePage) { admit(grant, inputs, sync) { flunk } }
    ensure
      owner.send(:remove_const, :MAX_INPUT_BYTES)
      owner.const_set(:MAX_INPUT_BYTES, limit)
    end
  end

  private
    def with_source
      with_provider_encryption do
        connection = create_provider_connection
        external = create_external_account(connection, external_id: "shared-upstream-id", identity_namespace: "institution:one",
          name: "Secret account name", sensitive_details: { "api_account_id" => "private-api-route" }, metadata: { "account_kind" => "cash" })
        account = connection.family.accounts.create!(name: "Request input test", currency: "USD", balance: 0, accountable: Depository.new)
        link = AccountProvider.create!(account: account, external_account: external)
        Account::SourcePolicy.select!(account: account, account_provider: link, resource: "balances")
        sync = connection.syncs.create!
        grant = Provider::AccountData::RequestGrant.new(connection).capture!(scope_sync: sync)
        inputs = Provider::AccountData::RequestInputs.new(connection: connection, sync: sync, stream: "balances", external_account: external,
          record_builder: lambda { |source|
            Ingestion::Record.account(external_id: source.external_id, name: source.name, currency: source.currency,
              account_type: source.account_type, balance: source.current_balance, sensitive_details: source.sensitive_details,
              metadata: source.metadata.merge("runtime_external_account_id" => source.id))
          })
        yield connection, external, sync, grant, inputs
      end
    end

    def window(sync)
      { "start" => 30.days.ago.utc.iso8601, "end" => sync.created_at.utc.iso8601 }
    end

    def admit(grant, inputs, sync, configuration: inputs.configuration, checkpoint: inputs.checkpoint_fingerprint(nil),
      cursor: nil, window: window(sync), request_key: SecureRandom.uuid)
      admission = nil
      _result, capture = grant.capture_request(scope_sync: sync, admit: lambda {
        admission = inputs.capture!(request_key: request_key, configuration: configuration, checkpoint: checkpoint, window: window, cursor: cursor)
      }) do |selected|
        assert_same admission, selected
        yield if block_given?
        Provider::AccountData::Page.new(records: [], complete: true)
      end
      [ admission, capture ]
    end

    def batch_for(connection, external, sync, admitted)
      create_provider_batch(connection, sync: sync, stream: "balances", external_account: external, scope_key: "account:#{external.id}",
        idempotency_key: admitted[:evidence].dig("scope", "request_key"), source_binding: admitted[:binding],
        source_policy_version: admitted[:binding]["source_policy_version"])
    end

    def verify(connection, sync, inputs, batch, admitted, capture)
      connection.with_lock do
        Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: capture, scope_sync: sync)
        inputs.verify!(batch: batch, evidence: admitted[:evidence])
      end
    end
end
