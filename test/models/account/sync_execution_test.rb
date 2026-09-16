require "test_helper"

class Account::SyncExecutionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  setup do
    @account = families(:empty).accounts.create!(name: "Serialized calculation", currency: "USD", balance: 0, accountable: Depository.new)
    @sync = @account.sync_later
  end

  teardown do
    # Explicit live-history cleanup remains permitted; materialization evidence
    # is not implicitly erased by Account destruction.
    @account.syncs.destroy_all
    @account.destroy!
    clear_enqueued_jobs
  end

  test "a busy account requeues its job without entering the financial calculation" do
    entered = Queue.new
    release = Queue.new
    holder = Thread.new do
      Account::SyncExecution.with(Sync.find(@sync.id)) do
        entered << true
        release.pop
      end
    end
    entered.pop
    assert_enqueued_with(job: SyncJob, args: [ @sync ]) do
      Account::SyncExecution.with(@sync) { flunk "a second worker entered the same account" }
    end
    assert @sync.reload.pending?
  ensure
    release << true if release
    holder&.value
  end

  test "a crashed syncing calculation resumes its same sealed input and completion marker" do
    @sync.start!
    @sync.update!(account_materialized_at: Time.current)
    seal = @sync.account_inputs_digest
    marker = @sync.account_materialized_at
    Account::SyncExecution.with(@sync) do
      assert @sync.pending?
      assert_equal seal, @sync.account_inputs_digest
      assert_equal marker, @sync.account_materialized_at
    end
  end

  test "exceptions release the session lock for a different worker" do
    assert_raises(RuntimeError) { Account::SyncExecution.with(@sync) { raise "worker failed" } }
    result = Thread.new do
      Account::SyncExecution.with(Sync.find(@sync.id)) { :entered }
    end.value
    assert_equal :entered, result
  end

  test "an unsealed sync cannot change its captured account before acquiring its session lock" do
    original = @account.syncs.create!
    replacement = accounts(:depository)
    assert_raises(ActiveRecord::StatementInvalid) do
      Sync.transaction(requires_new: true) { Sync.where(id: original.id).update_all(syncable_id: replacement.id) }
    end
    assert original.reload.pending?
    assert_equal @account.id, original.syncable_id
    assert_equal @account.family_id, original.account_family_id
    Account::SyncExecution.with(original) { |owner| assert_equal @account.id, owner.id }
  ensure
    original&.destroy!
  end

  test "a matching legacy queued job is sealed before its admitted worker is dispatched" do
    original = @account.syncs.create!
    assert_nil original.account_inputs_sealed_at
    Account::SyncExecution.with(original) do
      assert original.account_inputs_sealed_at
      assert_empty original.verify_account_inputs!
      assert_raises(ActiveRecord::StatementInvalid) do
        Sync.transaction(requires_new: true) { Sync.where(id: original.id).update_all(syncable_id: accounts(:depository).id) }
      end
    end
  end
end
