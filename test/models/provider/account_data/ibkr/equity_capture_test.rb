require "test_helper"
require_relative "../../../../support/provider_ingestion_test_helper"

class Provider::AccountData::Ibkr::EquityCaptureTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "captures an exact encrypted equity source and replayable account handoff without changing financial records" do
    with_capture do
      handoff = nil
      assert_no_difference [ "Entry.count", "Balance.count", "Holding.count" ] do
        assert_difference "IngestionBatch.count", 1 do
          handoff = capture
        end
      end
      result = handoff.resolve(account: @account, provider_sync: @sync)
      snapshot = Provider::AccountData::Ibkr::EquitySnapshot.load(result[:source_batch].payload)
      assert_equal @external.id, result[:external_account].id
      assert_equal @inventory.id, snapshot[:source_artifact]["inventory_batch_id"]
      assert_equal @sync.id, snapshot[:source_artifact]["provider_sync_id"]
      assert_equal Ingestion::HistoricalBalances.fingerprint(@inventory.payload), snapshot[:source_artifact]["inventory_payload_sha256"]
      assert_equal BigDecimal("3351"), snapshot[:imported_current_balance]
      assert_equal "CHF", snapshot[:currency]
      assert_equal @scope["observed_on"], snapshot[:observed_on].iso8601
      assert_provider_column_encrypted(result[:source_batch], :payload, "report_date")
      restored = Provider::AccountData::Ibkr::EquityHandoff.load(JSON.parse(JSON.generate(handoff.payload)))
      assert_equal result[:source_batch].id, restored.resolve(account: @account, provider_sync: @sync)[:source_batch].id
      assert_no_difference "IngestionBatch.count" do
        assert_equal handoff.payload, capture.payload
      end
    end
  end

  test "an older archive without a complete request grant retains strict epoch behavior" do
    with_capture do
      original = capture
      @connection.update!(writer_epoch: 2)
      assert_equal 1, @inventory.reload.writer_epoch
      assert_no_difference "IngestionBatch.count" do
        assert_raises(Provider::AccountData::StaleWriter) { capture(writer_epoch: 2) }
        assert_raises(Provider::AccountData::StaleWriter) { original.resolve(account: @account, provider_sync: @sync) }
      end
    end
  end

  test "capture rejects a source switch or expired epoch during preparation" do
    with_capture do
      fence = lambda do |&operation|
        @policy.update!(active: false)
        operation.call
      end
      assert_no_difference "IngestionBatch.count" do
        assert_raises(Provider::AccountData::StaleWriter) { capture(fence: fence) }
      end
    end
    with_capture do
      @connection.update!(writer_epoch: 2)
      assert_raises(Provider::AccountData::StaleWriter) { capture(writer_epoch: 1) }
    end
  end

  test "same sync recovery reuses the selected source and exact account child across worker epochs" do
    with_capture(grant: true) do
      original = capture
      child = enqueue(original)
      source = original.resolve(account: @account, provider_sync: @sync).fetch(:source_batch)
      plan = Ingestion::HistoricalBalances::IbkrPlan.new(external_account: @external, source_batch: source, capture_revision: child.id)
      command = plan.capture!(phase: "equity_history")
      @connection.update!(writer_epoch: 2)

      assert_no_difference [ "IngestionBatch.count", "Account::SyncInput.count", "Sync.count" ] do
        replay = capture
        assert_equal original.payload, replay.payload
        assert_equal child.id, enqueue(replay).id
        assert_equal source.id, replay.resolve(account: @account, provider_sync: @sync).fetch(:source_batch).id
      end
      assert_equal 1, source.reload.writer_epoch
      assert_equal 1, command.writer_epoch
      result = Ingestion::HistoricalBalances::Writer.new(batch: command).apply!
      assert result.fetch(:applied_rows).positive?
      assert command.reload.applied?
      assert @account.balances.exists?
    end
  end

  test "recovery between capture and enqueue retains the source and creates the missing selected child once" do
    with_capture(grant: true) do
      original = capture
      assert_not Account::SyncSource.exists?(account: @account)
      @connection.update!(writer_epoch: 2)
      replay = nil
      assert_no_difference [ "IngestionBatch.count", "Entry.count", "Balance.count" ] do
        replay = capture
        assert_equal original.payload, replay.payload
        assert_raises(Provider::AccountData::StaleWriter) { replay.resolve(account: @account, provider_sync: @sync) }
      end
      child = nil
      assert_difference "Account::SyncInput.count", 1 do
        child = enqueue(replay)
      end
      assert_equal child.id, enqueue(capture).id
      assert_equal original.payload.fetch("source_batch_id"), replay.resolve(account: @account, provider_sync: @sync).fetch(:source_batch).id
    end
  end

  test "original request credentials fence both recovered capture and historical publication" do
    with_capture(grant: true) do
      original = capture
      enqueue(original)
      resolved = original.resolve(account: @account, provider_sync: @sync)
      command = Ingestion::HistoricalBalances::IbkrPlan.new(**resolved).capture!(phase: "equity_history")
      @connection.update!(writer_epoch: 2, credentials: { "query_id" => "new-query", "token" => "replacement-token" })
      assert_no_difference [ "IngestionBatch.count", "Balance.count", "Entry.count" ] do
        assert_raises(Provider::AccountData::StaleWriter) { capture }
        assert_raises(Provider::AccountData::StaleWriter) { original.resolve(account: @account, provider_sync: @sync) }
        assert_raises(Provider::AccountData::StaleWriter) { Ingestion::HistoricalBalances::Writer.new(batch: command).apply! }
      end
      assert command.reload.captured?
    end
  end

  test "credentials changed after inventory cannot derive a new equity source" do
    with_capture(grant: true) do
      @connection.update!(credentials: { "query_id" => "changed-query", "token" => "replacement-token" })
      assert_no_difference "IngestionBatch.count" do
        assert_raises(Provider::AccountData::StaleWriter) { capture }
      end
    end
  end

  test "a different selected source rejects old child and command even at the same writer epoch" do
    with_capture(grant: true) do
      original = capture
      enqueue(original)
      original_sync, original_inventory = @sync, @inventory
      resolved = original.resolve(account: @account, provider_sync: @sync)
      command = Ingestion::HistoricalBalances::IbkrPlan.new(**resolved).capture!(phase: "equity_history")
      @sync = @connection.syncs.create!(created_at: original_sync.created_at)
      install_inventory(xml: file_fixture("ibkr/flex_statement.xml").read, grant: true)
      replacement = capture
      enqueue(replacement)

      assert_no_difference [ "Balance.count", "Entry.count", "IngestionBatch.count" ] do
        assert_raises(Provider::AccountData::StaleWriter) { original.resolve(account: @account, provider_sync: original_sync) }
        assert_raises(Provider::AccountData::StaleWriter) { Ingestion::HistoricalBalances::Writer.new(batch: command).apply! }
        @sync, @inventory = original_sync, original_inventory
        assert_raises(Provider::AccountData::StaleWriter) { capture }
      end
      assert command.reload.captured?
    end
  end

  test "missing required equity section and changed account units never become empty complete snapshots" do
    with_capture(xml: file_fixture("ibkr/flex_statement.xml").read.gsub(/<EquitySummaryInBase>.*?<\/EquitySummaryInBase>/m, "")) do
      assert_no_difference "IngestionBatch.count" do
        assert_raises(Provider::AccountData::IncompletePage) { capture }
      end
    end
    with_capture do
      @account.update!(currency: "USD")
      assert_raises(Provider::AccountData::InvalidResponse) { capture }
    end
  end

  test "handoff resolution requires the exact account and original provider sync" do
    with_capture do
      handoff = capture
      other_account = accounts(:investment)
      assert_raises(Provider::AccountData::InvalidResponse) { handoff.resolve(account: other_account, provider_sync: @sync) }
      next_sync = @connection.syncs.create!(created_at: @sync.created_at)
      assert_raises(Provider::AccountData::InvalidResponse) { handoff.resolve(account: @account, provider_sync: next_sync) }
    end
  end

  test "handoff does not accept altered batch digest artifact identity or observation date" do
    with_capture do
      handoff = capture
      { "equity_payload_sha256" => "b" * 64, "inventory_batch_id" => SecureRandom.uuid, "observed_on" => "2026-05-10" }.each do |key, value|
        changed = Provider::AccountData::Ibkr::EquityHandoff.new(handoff.payload.merge(key => value))
        assert_raises(Provider::AccountData::InvalidResponse) { changed.resolve(account: @account, provider_sync: @sync) }
      end
    end
  end

  test "revoked authority or disconnect invalidates queued handoffs" do
    with_capture do
      handoff = capture
      @policy.update!(active: false)
      assert_raises(Provider::AccountData::StaleWriter) { handoff.resolve(account: @account, provider_sync: @sync) }
    end
    with_capture do
      handoff = capture
      @connection.update!(scheduled_for_deletion: true)
      assert_raises(Provider::AccountData::StaleWriter) { handoff.resolve(account: @account, provider_sync: @sync) }
    end
  end

  test "retired ownership supports native capture and rollback pending rejects it" do
    with_capture do
      control = ProviderMigrationControl.create!(family: @account.family, provider_connection: @connection,
        provider_key: "ibkr", legacy_type: "IbkrItem", legacy_id: SecureRandom.uuid, state: "retired")
      handoff = capture
      assert_equal @external.id, handoff.resolve(account: @account, provider_sync: @sync)[:external_account].id
      control.update!(state: "rollback_pending")
      assert_raises(Provider::AccountData::StaleWriter) { capture }
      assert_raises(Provider::AccountData::StaleWriter) { handoff.resolve(account: @account, provider_sync: @sync) }
    end
  end

  test "link revisions remain pinned from artifact derivation through history planning" do
    with_capture do
      handoff = capture
      original = handoff.resolve(account: @account, provider_sync: @sync)
      @external.account_provider.touch
      assert_raises(Provider::AccountData::StaleWriter) { handoff.resolve(account: @account, provider_sync: @sync) }
      assert_raises(Provider::AccountData::StaleWriter) do
        Ingestion::HistoricalBalances::IbkrPlan.new(**original).prepare(phase: "opening_anchor")
      end
      replacement = capture
      assert_not_equal handoff.payload["source_batch_id"], replacement.payload["source_batch_id"]
      assert_equal @external.account_provider.reload.lock_version, replacement.payload["account_provider_revision"]
    end
  end

  private
    def with_capture(xml: file_fixture("ibkr/flex_statement.xml").read, grant: false)
      with_provider_encryption do
        DebugLogEntry.stubs(:capture)
        @connection = create_provider_connection(provider_key: "ibkr", writer_epoch: 1,
          credentials: { "query_id" => "test-query", "token" => "private-flex-token" })
        @sync = @connection.syncs.create!(created_at: Time.utc(2026, 5, 9, 12))
        install_inventory(xml: xml, grant: grant)
        @account = @connection.family.accounts.create!(name: "IBKR source capture", currency: "CHF", balance: "3351", accountable: Investment.new)
        @external = create_external_account(@connection, external_id: "U1234567", currency: "CHF")
        link = AccountProvider.create!(account: @account, external_account: @external)
        @policy = Account::SourcePolicy.select!(account: @account, account_provider: link, resource: "historical_balances")
        yield
      end
    end

    def install_inventory(xml:, grant:)
      @scope = Provider::AccountData::Ibkr::Archive.build(connection: @connection, sync: @sync, observed_at: @sync.created_at).fetch(:scope)
      reader = Provider::AccountData::Ibkr.new(client: nil, timezone: @scope["timezone"], observed_at: @sync.created_at, export_scope: @scope, staged_xml: xml)
      if grant
        request = Provider::AccountData::RequestGrant.new(@connection)
        request.with_adapter_snapshot(adapter: Provider::AccountData::Ibkr, observed_at: @sync.created_at, sync: @sync) { }
        page, proof = request.capture_request(scope_sync: @sync) { reader.list_accounts }
        page = Provider::AccountData::RequestGrant.attach(page, proof)
      else
        page = reader.list_accounts
      end
      @inventory = create_provider_batch(@connection, sync: @sync, payload: Ingestion::Codec.dump(page))
    end

    def enqueue(handoff)
      Account::SyncQueue.new(@account).enqueue(parent_sync: @sync, handoff: handoff)
    end

    def capture(writer_epoch: @connection.writer_epoch, fence: ->(&operation) { @connection.with_lock(&operation) })
      Provider::AccountData::Ibkr::EquityCapture.new(connection: @connection, sync: @sync, external_account: @external,
        source_batch_id: @inventory.id, writer_epoch: writer_epoch, fence: fence).capture!
    end
end
