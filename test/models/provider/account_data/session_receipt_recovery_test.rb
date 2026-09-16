require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::SessionReceiptRecoveryTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  class Client
    attr_accessor :fail_detail, :after_rotation, :unchanged, :empty_timeline
    attr_reader :requests

    def initialize(store)
      @store, @requests = store, []
    end

    def get_account
      read(:account)
      owner
    end

    def get_timeline_page(topic:, cursor: nil)
      raise ArgumentError unless cursor.nil?
      read(topic)
      rows = topic == "timelineTransactions" && !empty_timeline ? [ event ] : []
      { account: owner, response: { items: rows }, next_cursor: nil }
    end

    def get_event_detail(event_id:)
      read(:detail)
      raise Provider::TradeRepublicClient::ProviderUnavailable, "read failed after confirmed cookie" if fail_detail
      { account: owner, response: {} }
    end

    def owner
      { securitiesAccountNumber: "DE123", currency: "USD" }
    end

    private
      def read(key)
        @requests << key
        @store.with_session_lock do |session|
          original = session.credentials
          session.persist_session_credentials!(unchanged ? original : { "session_blob" => SecureRandom.uuid })
          after_rotation&.call(key, session)
        end
      end

      def event
        { id: "cash-event", timestamp: "2026-09-12T12:00:00Z", eventType: "INCOMING_TRANSFER", title: "Transfer",
          amount: { value: "10", currency: "USD" } }
      end
  end

  setup do
    DebugLogEntry.stubs(:capture)
    Provider::AccountData::Registry.stubs(:fetch).with("trade_republic").returns(Provider::AccountData::TradeRepublic)
  end

  test "confirmed cookies and v2 response receipt IDs commit and replay together" do
    with_connection do |connection, sync|
      adapter, client, = build(connection, sync)
      generation = runner(connection, sync, adapter).perform
      assert generation.applied?
      assert_equal 3, ProviderCredentialReceipt.where(provider_sync_generation: generation).count
      assert_equal 3, generation.pages.count
      generation.pages.each do |batch|
        capture = Ingestion::TransactionGroupCodec.load(batch.payload).evidence.fetch("request_grant")
        assert_equal 2, capture.fetch("version")
        assert_equal 1, capture.fetch("receipt_ids").size
        assert_empty capture.fetch("recovered_receipt_ids")
      end
      assert_equal [ "timelineTransactions", :detail, "timelineActivityLog" ], client.requests
      assert_equal 2, SourceRecord.where(external_account: connection.external_accounts, kind: "activity").count
    end
  end

  test "receipt insertion failure rolls back the cookie and never captures a page" do
    with_connection do |connection, sync|
      adapter, = build(connection, sync)
      original_credentials = connection.credentials
      ProviderCredentialReceipt.expects(:create!).raises(ActiveRecord::RecordInvalid.new(ProviderCredentialReceipt.new))
      assert_raises(Provider::AccountData::StaleWriter) { runner(connection, sync, adapter).perform }
      assert_equal original_credentials, connection.reload.credentials
      assert_equal 0, connection.credential_revision
      assert_empty ProviderCredentialReceipt.where(provider_connection: connection)
      assert_empty connection.provider_sync_generations.sole.pages
    end
  end

  test "failed detail receipts bridge only credentials and the missing detail is fetched again" do
    with_connection do |connection, sync|
      adapter, client, = build(connection, sync)
      client.fail_detail = true
      assert_raises(Provider::TradeRepublicClient::ProviderUnavailable) { runner(connection, sync, adapter).perform }
      generation = connection.provider_sync_generations.sole
      assert_equal 1, generation.pages.count
      assert_empty generation.children
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "activities")
      failed_receipt = ProviderCredentialReceipt.where(provider_sync_generation: generation).order(:to_revision).last
      assert_equal 1, failed_receipt.page_sequence

      resumed, resumed_client, = build(connection.reload, sync)
      assert runner(connection, sync, resumed).perform.applied?
      assert_equal [ :detail, "timelineActivityLog" ], resumed_client.requests
      detail_capture = Ingestion::TransactionGroupCodec.load(generation.pages.find_by!(sequence: 1).payload).evidence.fetch("request_grant")
      assert_equal [ failed_receipt.id ], detail_capture.fetch("recovered_receipt_ids")
      assert_equal 1, detail_capture.fetch("receipt_ids").size
      assert_equal 4, ProviderCredentialReceipt.where(provider_sync_generation: generation).count
    end
  end

  test "public syncer reuses exact completed discovery before same-Sync receipt recovery even without a retry counter" do
    with_connection(leased: false) do |connection, sync|
      first, client, = build(connection, sync)
      client.fail_detail = true
      assert_raises(Provider::AccountData::Error) { Provider::AccountData::Syncer.new(connection, adapter: first).perform_sync(sync) }
      assert_equal 0, sync.reload.provider_attempt
      assert_equal [ :account, "timelineTransactions", :detail ], client.requests
      refute connection.reload.lease_owner
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "activities")

      resumed, resumed_client, = build(connection, sync)
      Provider::AccountData::Syncer.new(connection, adapter: resumed).perform_sync(sync)
      assert_equal [ :detail, "timelineActivityLog" ], resumed_client.requests
      assert connection.provider_sync_generations.sole.applied?
      assert connection.provider_sync_checkpoints.find_by!(stream: "activities").provider_sync_generation.applied?
    end
  end

  test "expired lease blocks the next credential access even with unchanged cookies" do
    with_connection do |connection, sync|
      adapter, client, = build(connection, sync)
      client.unchanged = true
      client.after_rotation = lambda do |key, session|
        next unless key == "timelineTransactions"
        connection.update!(lease_expires_at: 1.second.ago)
        assert_raises(Provider::AccountData::StaleWriter) { session.credentials }
        raise Provider::AccountData::StaleWriter, "lease expired"
      end
      assert_raises(Provider::AccountData::StaleWriter) { runner(connection, sync, adapter).perform }
      assert_equal 0, connection.reload.credential_revision
      assert_empty ProviderCredentialReceipt.where(provider_connection: connection)
      assert_empty connection.provider_sync_generations.sole.pages
    end
  end

  test "cookie no-op captures no receipt and a missing receipt never authorizes a revision gap" do
    with_connection do |connection, sync|
      adapter, client, = build(connection, sync)
      client.unchanged = true
      client.empty_timeline = true
      assert runner(connection, sync, adapter).perform.applied?
      assert_empty ProviderCredentialReceipt.where(provider_connection: connection)
    end
    with_connection do |connection, sync|
      adapter, client, = build(connection, sync)
      client.fail_detail = true
      assert_raises(Provider::TradeRepublicClient::ProviderUnavailable) { runner(connection, sync, adapter).perform }
      ProviderCredentialReceipt.where(provider_connection: connection).order(:to_revision).last.delete
      resumed, resumed_client, = build(connection.reload, sync)
      assert_raises(Provider::AccountData::StaleWriter) { runner(connection, sync, resumed).perform }
      assert_empty resumed_client.requests
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "activities")
    end
  end

  test "another generation cannot borrow failed-attempt receipts" do
    with_connection do |connection, sync|
      adapter, client, = build(connection, sync)
      client.fail_detail = true
      assert_raises(Provider::TradeRepublicClient::ProviderUnavailable) { runner(connection, sync, adapter).perform }
      generation = connection.provider_sync_generations.sole
      generation.update!(status: "abandoned")
      other = connection.provider_sync_generations.create!(sync: sync, stream: "activities", writer_epoch: connection.writer_epoch,
        context_snapshot: generation.context_snapshot)
      receipt = ProviderCredentialReceipt.where(provider_connection: connection).order(:to_revision).last
      assert_raises(Provider::AccountData::StaleWriter) do
        ProviderCredentialReceipt.recover!(connection: connection, generation: other, page_sequence: 0,
          before: generation.context_snapshot.fetch("request_grant"), after: adapter.request_grant.snapshot)
      end
      assert_equal generation.id, receipt.provider_sync_generation_id
    end
  end

  private
    def with_connection(leased: true)
      with_provider_encryption do
        connection = create_provider_connection(provider_key: "trade_republic", credentials: { "session_blob" => "original-cookie" })
        if leased
          connection.update!(writer_epoch: 1, lease_owner: SecureRandom.uuid, lease_expires_at: 10.minutes.from_now)
        end
        %w[DE123 cash:DE123].each { |id| create_external_account(connection, external_id: id) }
        sync = connection.syncs.create!
        yield connection, sync
      ensure
        if connection
          SourceRecord.where(external_account: connection.external_accounts).delete_all
          ProviderCredentialReceipt.where(provider_connection: connection).delete_all
          ProviderSyncCheckpoint.where(provider_connection: connection).delete_all
          IngestionBatch.where(provider_connection: connection).delete_all
          ProviderSyncGeneration.where(provider_connection: connection).delete_all
          ExternalAccount.where(provider_connection: connection).delete_all
          Sync.where(syncable_type: "ProviderConnection", syncable_id: connection.id).delete_all
          ProviderConnection.where(id: connection.id).delete_all
        end
      end
    end

    def build(connection, sync)
      grant = Provider::AccountData::RequestGrant.new(connection).capture!(scope_sync: sync)
      client = Client.new(Provider::AccountData::CredentialStore.new(connection: connection, request_grant: grant))
      adapter = Provider::AccountData::TradeRepublic.new(client: client, timezone: "UTC", observed_at: sync.created_at, currency: "USD")
      adapter.bind_request_grant!(grant)
      [ adapter, client, grant ]
    end

    def runner(connection, sync, adapter)
      Provider::AccountData::TransactionSync.new(connection: connection, sync: sync, adapter: adapter, resource: "activities",
        writer_epoch: connection.writer_epoch, fence: ->(&block) { connection.with_lock(&block) })
    end
end
