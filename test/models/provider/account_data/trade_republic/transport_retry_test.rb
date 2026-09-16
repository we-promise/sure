require "test_helper"
require_relative "../../../../support/provider_ingestion_test_helper"

class Provider::AccountData::TradeRepublic::TransportRetryTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper
  self.use_transactional_tests = false

  class Client
    attr_accessor :store, :failure, :on_failure
    attr_reader :requests

    def initialize
      @requests = []
    end

    def get_account
      read(:account)
      owner
    end

    def get_timeline_page(topic:, cursor:)
      raise ArgumentError unless cursor.nil?
      read(topic)
      rows = topic == "timelineTransactions" ? [ { id: "cash-event", timestamp: "2026-09-12T12:00:00Z",
        eventType: "INCOMING_TRANSFER", title: "Transfer", amount: { value: "10", currency: "USD" } } ] : []
      { account: owner, response: { items: rows }, next_cursor: nil }
    end

    def get_event_detail(event_id:)
      read(:detail)
      if failure
        on_failure&.call
        raise failure
      end
      { account: owner, response: {} }
    end

    private
      def read(key)
        @requests << key
        store.with_session_lock do |session|
          session.credentials
          session.persist_session_credentials!("session_blob" => SecureRandom.uuid)
        end
      end

      def owner
        { securitiesAccountNumber: "DE123", currency: "USD" }
      end
  end

  setup do
    clear_enqueued_jobs
    @family_id = families(:dylan_family).id
    @family_sync_timestamps = Family.find(@family_id).attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
    DebugLogEntry.stubs(:capture)
    Sentry.stubs(:capture_exception)
    ProviderConnection.any_instance.stubs(:perform_post_sync)
    ProviderConnection.any_instance.stubs(:broadcast_sync_complete)
    Provider::AccountData::Registry.stubs(:fetch).with("trade_republic").returns(Provider::AccountData::TradeRepublic)
  end

  teardown do
    clear_enqueued_jobs
    Family.where(id: @family_id).update_all(@family_sync_timestamps) if @family_sync_timestamps
  end

  test "the full job defers a transient detail failure and consumes its scheduled same-Sync receipt recovery" do
    with_connection do |connection, sync, client|
      freeze_time
      begin
        client.failure = Provider::TradeRepublicClient::TransientProviderError.new("temporary transport failure")
        assert_enqueued_with(job: SyncJob, args: [ sync ], at: 15.seconds.from_now, queue: "high_priority") do
          SyncJob.perform_now(sync)
        end
        generation = connection.provider_sync_generations.sole
        original_created_at = sync.created_at
        assert sync.reload.pending?, sync.error
        assert_equal 1, sync.provider_attempt
        assert_equal 1, generation.transport_retry_count
        assert_equal 1, generation.page_count
        assert_empty generation.children
        assert_nil connection.provider_sync_checkpoints.find_by(stream: "activities")
        assert_nil connection.reload.lease_owner
        failed_receipt = ProviderCredentialReceipt.where(provider_sync_generation: generation).order(:to_revision).last
        assert_equal 1, failed_receipt.page_sequence

        before = client.requests.dup
        SyncJob.perform_now(Sync.find(sync.id))
        assert_equal before, client.requests
        client.failure = nil
        travel_to sync.resume_at do
          assert_no_difference "Sync.count" do
            perform_enqueued_jobs(only: SyncJob, at: Time.current)
          end
        end
        assert sync.reload.completed?, sync.error
        assert_equal original_created_at, sync.created_at
        assert_equal 1, sync.provider_attempt
        assert_equal [ :account, "timelineTransactions", :detail, :detail, "timelineActivityLog" ], client.requests
        assert generation.reload.applied?
        assert_equal 1, generation.transport_retry_count
        capture = Ingestion::TransactionGroupCodec.load(generation.pages.find_by!(sequence: 1).payload).evidence.fetch("request_grant")
        assert_equal [ failed_receipt.id ], capture.fetch("recovered_receipt_ids")
        assert_equal generation.id, connection.provider_sync_checkpoints.find_by!(stream: "activities").provider_sync_generation_id
        assert_empty connection.provider_sync_checkpoints.where(stream: "holdings")
      ensure
        travel_back
      end
    end
  end

  test "five transport retries exhaust the generation independently of pagination attempt count" do
    with_connection do |connection, sync, client|
      client.failure = Provider::TradeRepublicClient::Timeout.new("socket timeout")
      sync.update!(provider_attempt: 50)
      [ 15, 30, 60, 120, 240 ].each do |delay|
        current_time = sync.reload.resume_at || Time.current
        travel_to current_time do
          assert_enqueued_with(job: SyncJob, args: [ sync ], at: delay.seconds.from_now) { SyncJob.perform_now(Sync.find(sync.id)) }
          assert sync.reload.pending?, sync.error
        end
        clear_enqueued_jobs
      end
      generation = connection.provider_sync_generations.sole
      assert_equal 5, generation.transport_retry_count
      assert_equal 55, sync.provider_attempt
      travel_to sync.resume_at do
        assert_no_enqueued_jobs(only: SyncJob) { SyncJob.perform_now(Sync.find(sync.id)) }
      end
      assert sync.reload.failed?
      assert_equal 5, generation.reload.transport_retry_count
      assert_equal 1, generation.page_count
      assert_empty generation.children
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "activities")
      assert_equal 1, client.requests.count(:account)
    end
  end

  test "ordinary page-budget deferral does not consume a transport retry" do
    with_connection do |connection, sync, client|
      Provider::AccountData::TradeRepublic.any_instance.stubs(:activity_group_request_budget).returns(1)
      SyncJob.perform_now(sync)
      assert sync.reload.pending?, sync.error
      generation = connection.provider_sync_generations.sole
      assert_equal 0, generation.transport_retry_count
      clear_enqueued_jobs
      client.failure = Provider::TradeRepublicClient::Timeout.new("timeout")
      travel_to sync.resume_at do
        assert_enqueued_with(job: SyncJob, args: [ sync ], at: 15.seconds.from_now) { SyncJob.perform_now(Sync.find(sync.id)) }
      end
      assert sync.reload.pending?, sync.error
      assert_equal 2, sync.provider_attempt
      assert_equal 1, generation.reload.transport_retry_count
    end
  end

  test "authentication ownership malformed data and explicit capture limits remain terminal" do
    [ Provider::TradeRepublicClient::ProviderUnavailable, Provider::TradeRepublicClient::AuthenticationRequired,
      Provider::TradeRepublicClient::WafRequired, Provider::TradeRepublicClient::ConfigurationError,
      Provider::TradeRepublicClient::MalformedResponse, Provider::AccountData::InvalidResponse,
      Provider::AccountData::IncompletePage, Provider::AccountData::StaleWriter,
      Provider::AccountData::CredentialStore::ReauthorizationRequired ].each do |error_class|
      with_connection do |connection, sync, client|
        client.failure = error_class.new("permanent or unclassified failure")
        assert_no_enqueued_jobs(only: SyncJob) { SyncJob.perform_now(sync) }
        assert sync.reload.failed?, error_class.name
        assert_equal 0, sync.provider_attempt
        generation = connection.provider_sync_generations.sole
        assert_equal 0, generation.transport_retry_count
        assert_equal 1, generation.page_count
        assert_empty generation.children
        assert_nil connection.provider_sync_checkpoints.find_by(stream: "activities")
      end
    end
  end

  test "a transient error cannot schedule through a lost lease or an unrelated credential rotation" do
    [ :expired_lease, :unrecorded_credential ].each do |change|
      with_connection do |connection, sync, client|
        client.failure = Provider::TradeRepublicClient::TransientProviderError.new("temporary failure")
        client.on_failure = lambda do
          attributes = change == :expired_lease ? { lease_expires_at: 1.second.ago } : { credentials: { "session_blob" => "unrecorded" } }
          connection.reload.update!(attributes)
        end
        assert_no_enqueued_jobs(only: SyncJob) { SyncJob.perform_now(sync) }
        sync.reload
        assert(change == :expired_lease ? sync.syncing? : sync.failed?, change.to_s)
        assert_equal 0, connection.provider_sync_generations.sole.transport_retry_count
        assert_nil connection.provider_sync_checkpoints.find_by(stream: "activities")
      end
    end
  end

  test "rate limit delay respects a valid server boundary and rejects excessive or malformed supplied delays" do
    with_connection do |_connection, sync, client|
      client.failure = Provider::TradeRepublicClient::RateLimited.new("limited", retry_after: 120)
      freeze_time do
        assert_enqueued_with(job: SyncJob, args: [ sync ], at: 120.seconds.from_now) { SyncJob.perform_now(sync) }
      end
      assert sync.reload.pending?, sync.error
    end
    clear_enqueued_jobs
    [ 301, Float::NAN, Float::INFINITY, "120", -1 ].each do |delay|
      with_connection do |connection, sync, client|
        client.failure = Provider::TradeRepublicClient::RateLimited.new("limited", retry_after: delay)
        assert_no_enqueued_jobs(only: SyncJob) { SyncJob.perform_now(sync) }
        assert sync.reload.failed?, delay.inspect
        assert_equal 0, connection.provider_sync_generations.sole.transport_retry_count
      end
    end
  end

  test "the Plaid transaction path never applies the activity transport retry hook" do
    with_provider_encryption do
      connection = create_provider_connection(provider_key: "plaid")
      sync = connection.syncs.create!
      adapter = Provider::AccountData::Plaid.new(client: nil, timezone: "UTC", observed_at: sync.created_at, region: "us", item_id: "item")
      adapter.expects(:fetch_transaction_group).raises(Provider::TradeRepublicClient::TransientProviderError, "unclassified upstream failure")
      adapter.expects(:activity_group_retry_delay).never
      runner = Provider::AccountData::TransactionSync.new(connection: connection, sync: sync, adapter: adapter,
        writer_epoch: connection.writer_epoch, fence: ->(&block) { connection.with_lock(&block) })
      assert_raises(Provider::TradeRepublicClient::TransientProviderError) { runner.perform }
      assert connection.provider_sync_generations.sole.abandoned?
      assert_equal 0, connection.provider_sync_generations.sole.transport_retry_count
    ensure
      cleanup_connection(connection) if connection
    end
  end

  test "persisted retry counters cannot decrease skip revisions or belong to a transaction generation" do
    with_connection do |connection, sync, client|
      client.failure = Provider::TradeRepublicClient::Timeout.new("timeout")
      SyncJob.perform_now(sync)
      generation = connection.provider_sync_generations.sole
      [ 0, 3 ].each do |count|
        assert_not generation.update(transport_retry_count: count)
        generation.reload
      end
      [ -1, 17 ].each do |count|
        assert_raises(ActiveRecord::StatementInvalid) do
          ApplicationRecord.transaction(requires_new: true) { generation.update_columns(transport_retry_count: count) }
        end
        generation.reload
      end
      transaction = connection.provider_sync_generations.create!(sync: sync, stream: "transactions", writer_epoch: connection.writer_epoch, context_snapshot: {})
      assert_raises(ActiveRecord::StatementInvalid) do
        ApplicationRecord.transaction(requires_new: true) { transaction.update_columns(transport_retry_count: 1) }
      end
    end
  end

  private
    def with_connection
      with_provider_encryption do
        connection = create_provider_connection(provider_key: "trade_republic", credentials: { "session_blob" => "initial" })
        %w[DE123 cash:DE123].each { |id| create_external_account(connection, external_id: id) }
        sync = connection.syncs.create!
        client = Client.new
        Provider::TradeRepublicClient::IngestionClient.stubs(:new).with do |arguments|
          client.store = arguments.fetch(:credential_store)
          true
        end.returns(client)
        yield connection, sync, client
      ensure
        cleanup_connection(connection) if connection
      end
    end

    def cleanup_connection(connection)
      ProviderConnection.where(id: connection.id).update_all(lease_sync_id: nil, lease_owner: nil, lease_expires_at: nil)
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
