require "test_helper"
require_relative "../../../support/account_sync_input_test_helper"

class Account::Unlink::HandoffTest < ActiveSupport::TestCase
  include AccountSyncInputTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "unlink clears live selection while retaining sealed history and queues an empty manual calculation" do
    with_account_input do
      seed_account_history
      child = enqueue_account_handoff
      input = child.verify_account_inputs!.sole
      original_sync = child.attributes
      original_input = input.attributes
      original_batch = input.source_batch.attributes
      original_entries = @account.entries.order(:id).map(&:attributes)
      original_binding = @history_policy.source_binding

      assert unlink.call

      refute @account.reload.linked?
      assert_empty Account::SyncSource.where(account_id: @account.id)
      assert_equal original_sync, child.reload.attributes
      assert_equal original_input, input.reload.attributes
      assert_equal original_batch, input.source_batch.reload.attributes
      assert_equal original_entries, @account.entries.order(:id).map(&:attributes)
      assert_equal original_binding, @history_policy.reload.source_binding
      refute @history_policy.active?
      assert_raises(Provider::AccountData::StaleWriter) { input.resolve! }

      manual = @account.sync_later
      assert_equal child.id, manual.predecessor_id
      assert manual.account_inputs_sealed_at
      assert_empty manual.verify_account_inputs!
      assert_equal Account::SyncInput.digest([]), manual.account_inputs_digest
      assert_equal original_sync, child.reload.attributes
    end
  end

  test "a captured handoff cannot reinstall selection after unlink" do
    with_account_input do
      # EquityCapture has completed, but its child has not yet been queued.
      assert unlink.call

      assert_no_difference [ "Sync.count", "Account::SyncInput.count", "Account::SyncSource.count" ] do
        assert_raises(Provider::AccountData::StaleWriter) { enqueue_account_handoff }
      end
      assert_empty Account::SyncSource.where(account_id: @account.id)
      assert IngestionBatch.exists?(@handoff.payload.fetch("source_batch_id"))
    end
  end

  test "the final provider fence cannot reconnect an account unlinked after equity capture" do
    with_account_input do
      capture = mock("already completed exact equity capture")
      capture.expects(:capture!).returns(@handoff)
      Provider::AccountData::Ibkr::EquityCapture.expects(:new).returns(capture)
      entered_fence = false
      fence = lambda do |&block|
        entered_fence = true
        assert unlink.call
        @connection.with_lock(&block)
      end
      request = Provider::AccountData::Ibkr::AccountHandoff.new(connection: @connection, sync: @provider_sync,
        external_account: @external, writer_epoch: @connection.writer_epoch, fence: fence)

      assert_no_difference [ "Sync.count", "Account::SyncInput.count", "Account::SyncSource.count" ] do
        assert_raises(Provider::AccountData::StaleWriter) { request.enqueue! }
      end

      assert entered_fence
      refute @account.reload.linked?
      assert_empty Account::SyncSource.where(account_id: @account.id)
    end
  end

  test "a new historical policy revision rejects an older handoff before selecting a child" do
    with_account_input do
      @history_policy.update!(active: false)
      replacement = Account::SourcePolicy.select!(account: @account, account_provider: @link, resource: "historical_balances")

      assert_no_difference [ "Sync.count", "Account::SyncInput.count", "Account::SyncSource.count" ] do
        assert_raises(Provider::AccountData::StaleWriter) { enqueue_account_handoff }
      end

      assert replacement.reload.active?
      assert @account.reload.linked?
    end
  end

  private
    def unlink
      Account::Unlink.new(account: @account, user: @account.owner)
    end
end
