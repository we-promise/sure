require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::RequestExecutionGrantTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Grant = Provider::AccountData::RequestGrant
  Execution = Provider::AccountData::SyncExecution
  StaleWriter = Provider::AccountData::StaleWriter

  setup do
    Sentry.stubs(:capture_exception)
    @family_id = families(:dylan_family).id
    @family_sync_timestamps = Family.find(@family_id).attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
  end

  teardown do
    Family.where(id: @family_id).update_all(@family_sync_timestamps) if @family_sync_timestamps
  end

  test "adapter construction and ordinary cookie rotation use the live execution without generation receipts" do
    with_connection do |connection, sync, _parent|
      Execution.new(sync).perform do |execution|
        grant = Grant.new(connection, execution: execution)
        store = nil
        Provider::AccountData::Registry.stubs(:fetch).with("questrade").returns(Provider::AccountData::Questrade)
        Provider::AccountData::Questrade.expects(:build).with do |arguments|
          assert_operator ProviderConnection.connection.open_transactions, :>, 0
          store = arguments.fetch(:context).fetch(:credential_store)
          true
        end.returns(Provider::AccountData::Adapter.new(client: nil))
        adapter = Provider::AccountData::Registry.build(connection, observed_at: sync.created_at, sync: sync, request_grant: grant)
        assert_same grant, adapter.request_grant

        transport = mock("ordinary provider GET")
        transport.expects(:get).with do |credentials|
          assert_equal 0, ProviderConnection.connection.open_transactions
          credentials.fetch("session_blob") == "initial-cookie"
        end.returns("confirmed-response")
        response, capture = grant.capture_request do
          assert_equal 0, ProviderConnection.connection.open_transactions
          store.with_session_lock do |session|
            value = transport.get(session.credentials)
            session.persist_session_credentials!("session_blob" => "confirmed-cookie")
            assert_equal 0, ProviderConnection.connection.open_transactions
            assert_equal "confirmed-cookie", session.credentials.fetch("session_blob")
            value
          end
        end

        assert_equal "confirmed-response", response
        assert_equal 1, capture.fetch("version")
        assert_equal [ { "kind" => "session", "from_revision" => 0, "to_revision" => 1 } ], capture.fetch("rotations")
        refute capture.key?("receipt_ids")
        assert_equal 1, connection.reload.credential_revision
        assert_empty ProviderCredentialReceipt.where(provider_connection: connection)
        assert_empty connection.provider_sync_generations
        assert Grant.verify_capture!(connection: connection, capture: capture, require_runtime_inputs: true, scope_sync: sync)
        refute_includes JSON.generate(capture), "confirmed-cookie"
      end
    end
  end

  test "lease expiry during a request rejects reads no-op cookie writes and later captures" do
    with_connection do |connection, sync, _parent|
      Execution.new(sync).perform do |execution|
        grant, store = grant_and_store(connection, execution)
        grant.capture_request do
          store.with_session_lock do |session|
            original = session.credentials
            ProviderConnection.where(id: connection.id).update_all(lease_expires_at: 1.second.ago)
            assert_raises(StaleWriter) { session.credentials }
            assert_raises(StaleWriter) { session.persist_session_credentials!(original) }
            assert_raises(StaleWriter) { session.persist_session_credentials!("session_blob" => "must-not-persist") }
          end
        end
        assert_raises(StaleWriter) { grant.capture_request { flunk "Expired execution cannot issue HTTP" } }
        assert_raises(StaleWriter) { grant.with_adapter_snapshot { flunk "Expired execution cannot construct another adapter" } }
        assert_equal 0, connection.reload.credential_revision
        assert_equal "initial-cookie", connection.credentials.fetch("session_blob")
      end
    end
  end

  test "a replacement worker invalidates the retained session and cannot be adopted by the old grant" do
    with_connection do |connection, sync, _parent|
      Execution.new(sync).perform do |original_execution|
        grant, store = grant_and_store(connection, original_execution)
        replacement = nil
        grant.capture_request do
          store.with_session_lock do |session|
            original = session.credentials
            ProviderConnection.where(id: connection.id).update_all(lease_expires_at: 1.second.ago)
            Execution.new(Sync.find(sync.id)).perform do |current_execution|
              replacement = current_execution
              assert_operator current_execution.revision, :>, original_execution.revision
              assert_raises(StaleWriter) { session.credentials }
              assert_raises(StaleWriter) { session.persist_session_credentials!(original) }
              current = Grant.new(current_execution.connection, execution: current_execution).capture!
              assert current.verify!
            end
          end
        end
        assert replacement
        assert_raises(StaleWriter) { grant.bind_execution!(replacement) }
        assert_raises(StaleWriter) { grant.capture_request { flunk "Old worker cannot issue another request" } }
        assert_equal 0, connection.reload.credential_revision
        assert_equal replacement.lease_owner, connection.lease_owner
        assert_equal replacement.revision, Sync.find(sync.id).provider_execution_revision
      end
    end
  end

  test "fresh direct and ancestor cancellation stop an already admitted credential session" do
    [ :direct, :ancestor ].each do |target|
      with_connection(parent: true) do |connection, sync, parent|
        Execution.new(sync).perform do |execution|
          grant, store = grant_and_store(connection, execution)
          grant.capture_request do
            store.with_session_lock do |session|
              original = session.credentials
              cancelled = target == :direct ? sync : parent
              Sync.where(id: cancelled.id).update_all(cancel_requested_at: Time.current)
              # Both retained Ruby receivers still describe the old admission.
              assert_nil execution.sync.cancel_requested_at
              assert_nil parent.cancel_requested_at
              assert_raises(StaleWriter) { session.credentials }
              assert_raises(StaleWriter) { session.persist_session_credentials!(original) }
              assert_raises(StaleWriter) { session.persist_session_credentials!("session_blob" => "must-not-persist") }
            end
          end
          assert_raises(StaleWriter) { grant.capture_request { flunk "Cancellation cannot issue another request" } }
          assert_equal 0, connection.reload.credential_revision
          assert_equal "initial-cookie", connection.credentials.fetch("session_blob")
          assert_empty ProviderCredentialReceipt.where(provider_connection: connection)
        end
      end
    end
  end

  test "execution binding does not permit credential transport inside an enclosing row transaction" do
    with_connection do |connection, sync, _parent|
      Execution.new(sync).perform do |execution|
        grant, store = grant_and_store(connection, execution)
        grant.capture_request do
          ApplicationRecord.transaction do
            assert_raises(ArgumentError) do
              store.with_session_lock { flunk "Provider HTTP cannot start inside a financial transaction" }
            end
          end
          store.with_session_lock do |session|
            assert_equal "initial-cookie", session.credentials.fetch("session_blob")
            assert_equal 0, ProviderConnection.connection.open_transactions
          end
        end
        assert_equal 0, connection.reload.credential_revision
      end
    end
  end

  private
    def grant_and_store(connection, execution)
      grant = Grant.new(connection, execution: execution).capture!
      [ grant, Provider::AccountData::CredentialStore.new(connection: connection, request_grant: grant) ]
    end

    def with_connection(parent: false)
      with_provider_encryption do
        connection = create_provider_connection(provider_key: "questrade", credentials: { "session_blob" => "initial-cookie" })
        parent_sync = connection.family.syncs.create!(status: "syncing") if parent
        sync = connection.syncs.create!(parent: parent_sync)
        yield connection, sync, parent_sync
      ensure
        if connection
          ProviderConnection.where(id: connection.id).update_all(lease_sync_id: nil, lease_owner: nil, lease_expires_at: nil)
          ProviderCredentialReceipt.where(provider_connection: connection).delete_all
          Sync.where(syncable_type: "ProviderConnection", syncable_id: connection.id).delete_all
          ProviderConnection.where(id: connection.id).delete_all
        end
        Sync.where(id: parent_sync.id).delete_all if parent_sync
      end
    end
end
