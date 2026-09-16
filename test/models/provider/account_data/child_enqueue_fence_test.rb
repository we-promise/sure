require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::ChildEnqueueFenceTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  # Pause immediately after the final stream has committed, before child
  # dispatch. This is the gap a worker takeover must close.
  class PausedSyncer < Provider::AccountData::Syncer
    def initialize(connection, after_balance:, **options)
      super(connection, **options)
      @after_balance = after_balance
    end

    private
      def run_stream(stream, **options, &block)
        result = super
        @after_balance.call if stream == "balances"
        result
      end
  end

  setup do
    DebugLogEntry.stubs(:capture)
  end

  test "a worker replaced after its last stream cannot enqueue an ordinary account child" do
    with_provider_encryption do
      connection, external, = linked_connection
      sync = connection.syncs.create!
      Account.any_instance.expects(:sync_later).never
      after_balance = lambda do
        checkpoint = connection.provider_sync_checkpoints.find_by!(stream: "balances")
        assert checkpoint.ingestion_batch.applied?
        replacement = ProviderConnection.find(connection.id)
        replacement.update!(writer_epoch: replacement.writer_epoch + 1,
          lease_owner: "replacement-worker", lease_expires_at: 10.minutes.from_now)
      end
      syncer = PausedSyncer.new(connection, adapter: balance_adapter(external), after_balance: after_balance)

      assert_raises(Provider::AccountData::StaleWriter) { syncer.perform_sync(sync) }

      assert_empty sync.children
      assert_equal "replacement-worker", connection.reload.lease_owner
      assert connection.provider_sync_checkpoints.find_by!(stream: "balances").ingestion_batch.applied?
    end
  end

  test "an admitted ordinary account child retains its original parent and window" do
    with_provider_encryption do
      connection, external, = linked_connection
      sync = connection.syncs.create!(window_start_date: Date.current - 30, window_end_date: Date.current)
      Account.any_instance.expects(:sync_later).with(parent_sync: sync,
        window_start_date: sync.window_start_date, window_end_date: sync.window_end_date).once

      Provider::AccountData::Syncer.new(connection, adapter: balance_adapter(external)).perform_sync(sync)
    end
  end

  test "an IBKR handoff prepared before takeover cannot enqueue afterward" do
    with_provider_encryption do
      connection, external, account = linked_connection(provider_key: "ibkr")
      sync = connection.syncs.create!
      connection.update!(writer_epoch: 1, lease_owner: "preparing-worker", lease_expires_at: 10.minutes.from_now)
      handoff = Object.new
      prepare_handoff(connection, external, sync, handoff) do
        ProviderConnection.find(connection.id).update!(writer_epoch: 2,
          lease_owner: "replacement-worker", lease_expires_at: 10.minutes.from_now)
      end
      Account::SyncQueue.expects(:new).never
      dispatcher = Provider::AccountData::Ibkr::AccountHandoff.new(connection: connection, sync: sync,
        external_account: external, writer_epoch: 1, fence: lease_fence(connection, 1, "preparing-worker"))

      assert_raises(Provider::AccountData::StaleWriter) { dispatcher.enqueue! }

      assert_empty sync.children
      assert_empty account.syncs.where(parent: sync)
      assert_equal "replacement-worker", connection.reload.lease_owner
    end
  end

  test "an admitted IBKR handoff reaches the queue unchanged" do
    with_provider_encryption do
      connection, external, account = linked_connection(provider_key: "ibkr")
      sync = connection.syncs.create!(window_start_date: Date.current - 20, window_end_date: Date.current)
      connection.update!(writer_epoch: 1, lease_owner: "preparing-worker", lease_expires_at: 10.minutes.from_now)
      handoff = Object.new
      prepare_handoff(connection, external, sync, handoff)
      queue = mock("account input queue")
      Account::SyncQueue.expects(:new).with(account).returns(queue)
      queue.expects(:enqueue).with(parent_sync: sync, window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date, handoff: handoff).returns(:queued)
      dispatcher = Provider::AccountData::Ibkr::AccountHandoff.new(connection: connection, sync: sync,
        external_account: external, writer_epoch: 1, fence: lease_fence(connection, 1, "preparing-worker"))

      assert_equal :queued, dispatcher.enqueue!
    end
  end

  test "cancellation after IBKR preparation still prevents child dispatch" do
    with_provider_encryption do
      connection, external, = linked_connection(provider_key: "ibkr")
      sync = connection.syncs.create!(status: "syncing")
      connection.update!(writer_epoch: 1, lease_owner: "preparing-worker", lease_expires_at: 10.minutes.from_now)
      prepare_handoff(connection, external, sync, Object.new) { sync.update!(cancel_requested_at: Time.current) }
      Account::SyncQueue.expects(:new).never
      dispatcher = Provider::AccountData::Ibkr::AccountHandoff.new(connection: connection, sync: sync,
        external_account: external, writer_epoch: 1, fence: lease_fence(connection, 1, "preparing-worker"))

      assert_nil dispatcher.enqueue!
      assert_empty sync.children
    end
  end

  private
    def linked_connection(provider_key: "up")
      connection = create_provider_connection(provider_key: provider_key)
      external = create_external_account(connection, external_id: "child-source")
      account = Account.create!(family: connection.family, name: "Child fence account", currency: "USD",
        balance: 0, accountable: Depository.create!)
      link = AccountProvider.create!(account: account, external_account: external)
      Account::SourcePolicy.select!(account: account, account_provider: link, resource: "balances")
      [ connection, external, account ]
    end

    def balance_adapter(external)
      page = Provider::AccountData::Page.new(records: [ Ingestion::Record.account(
        external_id: external.external_id, name: "Child fence account", currency: "USD") ], complete: true, mode: "snapshot")
      adapter = stub(capabilities: [])
      adapter.stubs(:list_accounts).returns(page)
      adapter.stubs(:fetch_balance).returns(page)
      adapter
    end

    def prepare_handoff(connection, external, sync, handoff, &after_capture)
      batch = create_provider_batch(connection, sync: sync)
      Provider::AccountData::Ibkr::Archive.expects(:build).with(connection: connection, sync: sync,
        observed_at: sync.created_at).returns({ source_batch_id: batch.id })
      capture = Object.new
      capture.define_singleton_method(:capture!) do
        after_capture&.call
        handoff
      end
      Provider::AccountData::Ibkr::EquityCapture.expects(:new).with do |arguments|
        arguments[:connection] == connection && arguments[:sync] == sync &&
          arguments[:external_account] == external && arguments[:source_batch_id] == batch.id
      end.returns(capture)
    end

    def lease_fence(connection, epoch, owner)
      lambda do |&block|
        connection.with_lock do
          unless connection.writer_epoch == epoch && connection.lease_owner == owner && connection.lease_expires_at > Time.current
            raise Provider::AccountData::StaleWriter, "Provider worker lost its lease"
          end
          block.call
        end
      end
    end
end
